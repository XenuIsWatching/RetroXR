"""SCons platform tool: godot-cpp's own `android` tool, plus native thread-local storage.

Handed to godot-cpp through its `custom_tools=` option, which puts this directory
ahead of godot-cpp's own `tools/` on the tool path, so this file is what loads
for platform=android - for the godot-cpp library build and for every extension,
since each extension makes its environment through godot-cpp's SConstruct.

Why: clang's Android default is EMULATED TLS, where every `thread_local` access
is a call into __emutls_get_address plus a pthread_getspecific. godot-cpp's
Wrapped touches three thread_locals on every object construction and the
libretro bridge one on every callback; measured at ~2% of a Quest 3's main
thread. `-fno-emulated-tls` makes each access one load off the thread pointer.
It has to reach godot-cpp AND the extensions alike - the extensions read
godot-cpp's thread_locals inline, and the two TLS models do not link - and
godot-cpp's SConstruct takes no compiler flags, hence a tool rather than an
argument. The result needs Android 10 or newer to load; the Quest is well past
that, and it is the only Android target.

SCons keys rebuilds on the command line, so switching this on or off wants the
android objects and godot-cpp's android static libraries removed first.
"""

import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_GODOT_CPP_TOOLS = os.path.normpath(
    os.path.join(_HERE, "..", "..", "libretro-godot", "godot-cpp", "tools"))
if _GODOT_CPP_TOOLS not in sys.path:
    # The real tool imports its siblings (common_compiler_flags, my_spawn) by name.
    sys.path.insert(0, _GODOT_CPP_TOOLS)

_spec = importlib.util.spec_from_file_location(
    "godot_cpp_android", os.path.join(_GODOT_CPP_TOOLS, "android.py"))
_real = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_real)


def options(opts):
    _real.options(opts)


def exists(env):
    return _real.exists(env)


def generate(env):
    _real.generate(env)
    env.Append(CCFLAGS=["-fno-emulated-tls"], LINKFLAGS=["-fno-emulated-tls"])
