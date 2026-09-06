// VerletRope — the per-tick simulation. Split from VerletRope.cpp, which holds
// the bindings and lifecycle, purely to keep both files readable.
//
// Ported from verlet_rope.gd. Constraint order, contact caching and sleep rules
// all match it; where the GDScript had constraints hand-inlined into the solver
// loop to dodge interpreter call overhead, they are ordinary inline functions
// again here.

#include "VerletRope.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <queue>

using namespace godot;

namespace Xenu
{

namespace
{
constexpr int SLEEP_FRAMES = 45;
constexpr double SLEEP_MAX_VELOCITY_EPS_SQ = 0.0025 * 0.0025;
constexpr double SLEEP_RMS_VELOCITY_EPS_SQ = 0.0004 * 0.0004;
// These are sanity gates, not equilibrium tolerances: a deliberately heaped
// cord begins extremely compressed and can retain large local constraint error
// while being perfectly motionless. Velocity decides rest; residuals only stop
// a pathological/tunnelled solve from being frozen and hidden.
constexpr double SLEEP_STRETCH_ERROR = 4.0;
constexpr double SLEEP_CONTACT_ERROR = 0.05;
constexpr double WAKE_ANCHOR_EPS_SQ = 0.0005 * 0.0005;
// A sleeping rope has no CollisionObject3D of its own, so furniture cannot wake
// it through a physics callback. Poll its cached contacts at a low cadence:
// three times a second at the project's 90 Hz tick catches moved support
// without turning every sleeping cable back into a per-frame physics cost.
// A poll is one shape query per segment and one point query per particle,
// and with eight sleeping cables in a room the 15-tick cadence was 3% of a
// Quest 3's main thread; two polls have to agree before a wake, so the worst
// case from a removed support to the cord falling is 60 ticks.
constexpr int SLEEP_ENVIRONMENT_INTERVAL = 30;
// Further than an anchor can travel in one tick by being carried or thrown: 0.4 m
// at 60 Hz is 24 m/s, where a hard throw is nearer 10. Every teleport a restore
// performs is 0.7 m or more, so the gap is wide. See AnchorTeleported.
constexpr double TELEPORT_EPS_SQ = 0.4 * 0.4;
// Largest rotation AlignAnchorPlug may apply in one tick, radians. The rotation
// is about the cable anchor, some 40 mm from the body origin, and it is written
// as a transform — a teleport the physics server never sweeps. Uncapped, a cord
// whipping during a drop flips the tangent and the alignment arcs the origin
// ~90 mm in a single write, far past the server's depenetration recovery: a
// dropped lead's plug was carried clean through a 100 mm floor slab and fell
// out of the world. 0.12 rad keeps the arc under ~5 mm a tick — unescapably
// inside contact recovery — and still turns a full flip in a third of a second.
constexpr double MAX_ALIGN_STEP = 0.12;
} // namespace

// ── Constraint primitives ───────────────────────────────────────────────────

// Positional constraint between points a/b toward rest distance, split by
// inverse mass.
inline void VerletRope::SolvePair(int a, int b, double rest, double k, double *lambda)
{
    const float w_a = m_inv_mass[a];
    const float w_b = m_inv_mass[b];
    const float w_sum = w_a + w_b;
    if (w_sum == 0.0f)
        return;
    const Vector3 diff = m_points[b] - m_points[a];
    const double dist = diff.length();
    if (dist < 0.0001)
        return;
    if (lambda == nullptr || m_stretch_compliance <= 0.0)
    {
        // Keep the authored-stiffness path arithmetically identical to the
        // pre-XPBD solver. Settling is chaotic enough that even reassociating
        // these multiplies changes a pose several metres down a translated test.
        const Vector3 correction = diff * ((dist - rest) / dist) * k;
        m_points[a] += correction * (w_a / w_sum);
        m_points[b] -= correction * (w_b / w_sum);
        return;
    }
    const double alpha = m_stretch_compliance / m_step_dt_sq;
    const double c = dist - rest;
    const double delta_lambda = (-c - alpha * *lambda) / (w_sum + alpha);
    *lambda += delta_lambda;
    const Vector3 correction = diff * (-delta_lambda / dist);
    m_points[a] += correction * (w_a / w_sum);
    m_points[b] -= correction * (w_b / w_sum);
}

// Angular bend constraint: pull particle b toward the midpoint of its
// neighbours at +/-spacing (momentum-balanced), ignoring deviation below
// allowed_dev.
inline void VerletRope::SolveBend(int b, int spacing, double allowed_dev, double k)
{
    SolveBendTriple(b - spacing, b, b + spacing, allowed_dev, k);
}

// The same constraint over three arbitrary particles. A branch's link back to
// the trunk is not evenly spaced in the array — the junction's neighbours are
// the trunk's last particle and a branch's first, which live nowhere near each
// other — so the spacing form above cannot express it.
inline void VerletRope::SolveBendTriple(int a, int b, int c, double allowed_dev, double k)
{
    const float w_a = m_inv_mass[a];
    const float w_b = m_inv_mass[b];
    const float w_c = m_inv_mass[c];
    const float w_total = w_b + 0.5f * (w_a + w_c);
    if (w_total == 0.0f)
        return;
    const Vector3 delta = (m_points[a] + m_points[c]) * 0.5f - m_points[b];
    const double dev_sq = delta.length_squared();
    // The degenerate case has to be dropped rather than scaled: nudging an
    // already-straight triple by a fraction of a micrometre is what used to stop
    // a settled rope going to sleep.
    if (dev_sq < 1e-8)
        return;
    const double dev = std::sqrt(dev_sq);
    if (allowed_dev > 0.0 && dev <= allowed_dev)
        return;

    Vector3 v;
    if (allowed_dev > 0.0)
    {
        v = delta * ((dev - allowed_dev) / dev * k);
    }
    else
    {
        // No free-bend allowance makes the (dev - allowed) / dev scale exactly
        // 1, so the correction is delta * k and the length is never needed. This
        // is the default path: max_bend_degrees is 0 unless a rope opts in, and
        // the strain-relief stub always passes 0.
        v = delta * k;
    }
    if (m_bend_compliance > 0.0)
    {
        const double alpha = m_bend_compliance / m_step_dt_sq;
        Vector3 &lambda = m_bend_lambda[BendLambdaKey(a, b, c, false, allowed_dev, k)];
        const Vector3 delta_lambda = (v / k - lambda * alpha) / (w_total + alpha);
        lambda += delta_lambda;
        m_points[b] += delta_lambda * w_b;
        m_points[a] -= delta_lambda * (0.5f * w_a);
        m_points[c] -= delta_lambda * (0.5f * w_c);
    }
    else
    {
        m_points[b] += v * (w_b / w_total);
        m_points[a] -= v * (0.5f * w_a / w_total);
        m_points[c] -= v * (0.5f * w_c / w_total);
    }
}

// True local angular bending. Stiffness controls the correction toward the free
// angle, resistance ramps progressively near a fold, and the hard limit handles
// adjacent segments that self-collision deliberately excludes.
inline void VerletRope::SolveAngleBend(int a, int b, int c, double free_angle, double k)
{
    const Vector3 incoming = m_points[b] - m_points[a];
    const Vector3 outgoing = m_points[c] - m_points[b];
    const double incoming_len = incoming.length();
    const double outgoing_len = outgoing.length();
    if (incoming_len < 1e-6 || outgoing_len < 1e-6)
        return;
    const Vector3 u = incoming / incoming_len;
    const Vector3 v_out = outgoing / outgoing_len;
    const double forward_dot = CLAMP(u.dot(v_out), -1.0, 1.0);
    const double turn = std::acos(forward_dot);
    const double stiffen = Math::deg_to_rad(CLAMP(m_bend_stiffen_degrees, 0.0, 180.0));
    const double limit = Math::deg_to_rad(
        CLAMP(std::max(m_bend_limit_degrees, m_bend_stiffen_degrees + 0.001), 0.0, 180.0));
    if (turn <= stiffen)
        return;

    double k_eff = CLAMP(k, 0.0, 1.0);
    double target_turn;
    if (turn > limit)
        target_turn = limit;
    else
    {
        const double t = turn > stiffen
                             ? CLAMP((turn - stiffen) / (limit - stiffen), 0.0, 1.0)
                             : 0.0;
        const double ramp = t * t * (3.0 - 2.0 * t);
        // Multiply the authored response progressively rather than blending
        // toward rigidity. A soft cable remains softer than a stiff one even
        // near the limit; only the separate hard-limit branch is absolute.
        k_eff = 1.0 - std::pow(1.0 - k_eff, 1.0 + ramp * 12.0);
        target_turn = turn - (turn - stiffen) * k_eff;
    }
    const Vector3 reference = std::abs(u.dot(Vector3(0, 1, 0))) < 0.9
                                  ? Vector3(0, 1, 0)
                                  : Vector3(1, 0, 0);
    const Vector3 stable_axis = u.cross(reference).normalized();
    Vector3 axis = u.cross(v_out);
    if (axis.length_squared() < 1e-10)
        axis = stable_axis;
    else
    {
        axis.normalize();
        if (axis.dot(stable_axis) < 0.0)
            axis = -axis;
    }
    const double sin_turn = std::sqrt(std::max(0.0, 1.0 - forward_dot * forward_dot));
    const float w_b = m_inv_mass[b];
    const float w_c = m_inv_mass[c];
    const float w_a = m_inv_mass[a];

    // At an exact hairpin the angle gradient is undefined. One deterministic
    // angular projection breaks the symmetry; subsequent iterations use the
    // regular three-particle gradient below.
    if (sin_turn < 1e-5)
    {
        const Vector3 target = Basis(axis, target_turn).xform(u) * outgoing_len;
        const Vector3 correction = target - outgoing;
        const float w_sum = w_b + w_c;
        if (w_sum > 0.0f)
        {
            m_points[b] -= correction * (w_b / w_sum);
            m_points[c] += correction * (w_c / w_sum);
        }
        return;
    }

    const Vector3 g_a = (v_out - u * forward_dot) / (incoming_len * sin_turn);
    const Vector3 g_c = -(u - v_out * forward_dot) / (outgoing_len * sin_turn);
    const Vector3 g_b = -g_a - g_c;
    const double weight = w_a * g_a.length_squared() +
                          w_b * g_b.length_squared() +
                          w_c * g_c.length_squared();
    if (weight < 1e-10)
        return;

    // Angle gradients preserve segment lengths only to first order. Bound a
    // nonlinear correction so one iteration cannot manufacture stretch while
    // trying to open a severe fold; repeated solver iterations converge it.
    const double constraint = std::min(turn - target_turn, Math::deg_to_rad(5.0));
    const uint64_t key = BendLambdaKey(a, b, c, false, free_angle, k);
    double &lambda = m_angle_lambda[key];
    const double alpha = m_bend_compliance > 0.0 ? m_bend_compliance / m_step_dt_sq : 0.0;
    const double delta_lambda = (-constraint - alpha * lambda) / (weight + alpha);
    lambda += delta_lambda;
    m_points[a] += g_a * (w_a * delta_lambda);
    m_points[b] += g_b * (w_b * delta_lambda);
    m_points[c] += g_c * (w_c * delta_lambda);
}

// Bend on (a, b, c) with `a` held immovable — the correction is shared by b and c
// only.
//
// For a junction: it is one particle shared by the trunk and every branch, and
// letting each branch push it turns a three-way fray into a tug of war. Each
// branch straightening its own first particle is wanted; three of them elbowing
// the breakout every iteration is what stopped a lead ever settling on a table.
inline void VerletRope::SolveBendAnchored(int a, int b, int c, double k)
{
    const float w_b = m_inv_mass[b];
    const float w_c = m_inv_mass[c];
    const float w_total = w_b + 0.5f * w_c;
    if (w_total == 0.0f)
        return;
    const Vector3 delta = (m_points[a] + m_points[c]) * 0.5f - m_points[b];
    if (delta.length_squared() < 1e-8)
        return;
    const Vector3 v = delta * k;
    if (m_bend_compliance > 0.0)
    {
        const double alpha = m_bend_compliance / m_step_dt_sq;
        Vector3 &lambda = m_bend_lambda[BendLambdaKey(a, b, c, true, 0.0, k)];
        const Vector3 delta_lambda = (delta - lambda * alpha) / (w_total + alpha);
        lambda += delta_lambda;
        m_points[b] += delta_lambda * w_b;
        m_points[c] -= delta_lambda * (0.5f * w_c);
    }
    else
    {
        m_points[b] += v * (w_b / w_total);
        m_points[c] -= v * (0.5f * w_c / w_total);
    }
}

uint64_t VerletRope::BendLambdaKey(int a, int b, int c, bool anchored,
                                   double allowed_dev, double strength) const
{
    uint64_t key = (static_cast<uint64_t>(anchored) << 63) |
                   (static_cast<uint64_t>(a & 0x1fffff) << 42) |
                   (static_cast<uint64_t>(b & 0x1fffff) << 21) |
                   static_cast<uint64_t>(c & 0x1fffff);
    // The same triple may carry both the ordinary cable bend and a stronger
    // strain-relief constraint. Keep their multipliers independent.
    key ^= static_cast<uint64_t>(std::hash<double>{}(allowed_dev)) * 0x9e3779b97f4a7c15ULL;
    key ^= static_cast<uint64_t>(std::hash<double>{}(strength)) * 0xbf58476d1ce4e5b9ULL;
    return key;
}

// Keep segment s's midpoint outside its cached contact plane, splitting the
// correction so the midpoint clears fully. The distance cap guards against stale
// planes (refreshed only every raycast_interval frames, and infinite in extent).
inline void VerletRope::SolveMidContact(int s, bool second)
{
    const int ia = m_seg_a[s];
    const int ib = m_seg_b[s];
    const float w_a = m_inv_mass[ia];
    const float w_b = m_inv_mass[ib];
    const float w_sum = w_a + w_b;
    if (w_sum == 0.0f)
        return;
    const double t = second ? m_mid_contact_t_2[s] : m_mid_contact_t[s];
    const double ta = 1.0 - t;
    const Vector3 mid = m_points[ia] * ta + m_points[ib] * t;
    const double rest = m_seg_rest[s];
    const Vector3 &contact_point = second ? m_mid_contact_point_2[s] : m_mid_contact_point[s];
    const Vector3 &contact_normal = second ? m_mid_contact_normal_2[s] : m_mid_contact_normal[s];
    if (mid.distance_squared_to(contact_point) > rest * rest * 4.0)
        return;
    const Vector3 n = contact_normal;
    const double d = (mid - contact_point).dot(n);
    if (d >= m_collision_radius)
        return;
    double push_distance = m_collision_radius - d;
    if (m_contact_compliance > 0.0)
    {
        const double alpha = m_contact_compliance / m_step_dt_sq;
        double &lambda = second ? m_mid_contact_lambda_2[s] : m_mid_contact_lambda[s];
        const double old_lambda = lambda;
        const double weight = w_a * ta * ta + w_b * t * t;
        const double delta_lambda = (push_distance - alpha * old_lambda) / (weight + alpha);
        lambda = std::max(0.0, old_lambda + delta_lambda);
        push_distance = lambda - old_lambda;
        m_points[ia] += n * (ta * w_a * push_distance);
        m_points[ib] += n * (t * w_b * push_distance);
    }
    else
    {
        const Vector3 push = n * push_distance;
        const double weight = w_a * ta * ta + w_b * t * t;
        if (weight <= 0.0)
            return;
        m_points[ia] += push * (w_a * ta / weight);
        m_points[ib] += push * (w_b * t / weight);
    }
}

// Keep particle i at least collision_radius outside the cached plane.
inline void VerletRope::ProjectPlane(int i, const Vector3 &cp, const Vector3 &n, double &lambda)
{
    const double d = (m_points[i] - cp).dot(n);
    if (d < m_collision_radius)
    {
        if (m_contact_compliance <= 0.0)
        {
            m_points[i] += n * (m_collision_radius - d);
            return;
        }
        const double alpha = m_contact_compliance / m_step_dt_sq;
        const double delta_lambda = (m_collision_radius - d - alpha * lambda) /
                                    (m_inv_mass[i] + alpha);
        const double old_lambda = lambda;
        lambda = std::max(0.0, lambda + delta_lambda);
        m_points[i] += n * (m_inv_mass[i] * (lambda - old_lambda));
    }
}

void VerletRope::PinAnchors()
{
    if (m_start_cached)
    {
        m_points[0] = AnchorPoint(m_start_cached, m_start_anchor_offset, m_points[0]);
        m_prev_points[0] = m_points[0];
    }
    if (m_end_cached)
    {
        const int last = TrunkCount() - 1;
        m_points[last] = AnchorPoint(m_end_cached, m_end_anchor_offset, m_points[last]);
        m_prev_points[last] = m_points[last];
    }
    for (const FrayChain &fc : m_fray)
    {
        if (fc.cached == nullptr)
            continue;
        const int last = fc.first + fc.count - 1;
        m_points[last] = AnchorPoint(fc.cached, fc.offset, m_points[last]);
        m_prev_points[last] = m_points[last];
    }
}

// True when an anchor is further from the particle pinned to it than it could have
// been carried since the last tick. PinAnchors puts that particle exactly on the
// anchor every tick, so the gap IS how far the anchor moved, and no extra state is
// needed to measure it.
bool VerletRope::AnchorTeleported() const
{
    if (m_points.empty())
        return false;
    if (m_start_cached != nullptr &&
        AnchorPoint(m_start_cached, m_start_anchor_offset, m_points[0])
                .distance_squared_to(m_points[0]) > TELEPORT_EPS_SQ)
        return true;
    if (m_end_cached != nullptr)
    {
        const int last = TrunkCount() - 1;
        if (AnchorPoint(m_end_cached, m_end_anchor_offset, m_points[last])
                .distance_squared_to(m_points[last]) > TELEPORT_EPS_SQ)
            return true;
    }
    for (const FrayChain &fc : m_fray)
    {
        if (fc.cached == nullptr)
            continue;
        const int last = fc.first + fc.count - 1;
        if (AnchorPoint(fc.cached, fc.offset, m_points[last]).distance_squared_to(m_points[last]) >
            TELEPORT_EPS_SQ)
            return true;
    }
    return false;
}

// Snap point i to just outside a surface and convert its velocity into a
// friction-damped slide along the surface (no bounce).
inline void VerletRope::ResolveContact(int i, const Vector3 &contact, const Vector3 &normal)
{
    const Vector3 vel = m_points[i] - m_prev_points[i];
    const Vector3 tangential = vel - normal * vel.dot(normal);
    m_points[i] = contact + normal * m_collision_radius;
    m_prev_points[i] = m_points[i] - tangential * (1.0 - m_surface_friction);
}

// Stub stiffness at the k-th particle from an end (k = 1 nearest), over n stub
// particles. Full strength at the plug, easing to nothing at the far end — a
// constant strength across the stub made the cable look like sausage links,
// because a rigid run met a floppy run at a hard boundary.
double VerletRope::StubWeight(double base, int k, int n) const
{
    if (n <= 1)
        return base;
    return base * (1.0 - static_cast<double>(k - 1) / static_cast<double>(n));
}

// Whether a cached contact plane is still plausible for particle i: the particle
// hasn't slid far from the contact and still sits near the plane.
bool VerletRope::PlaneValid(int i, const Vector3 &cp, const Vector3 &n) const
{
    const Vector3 p = m_points[i];
    if (p.distance_squared_to(cp) > m_segment_length * m_segment_length * 4.0)
        return false;
    return std::abs((p - cp).dot(n)) < m_collision_radius * 3.0;
}

// ── Plug orientation ────────────────────────────────────────────────────────

// True when this anchor's orientation is externally fixed, so the cable should
// leave it stiffly along its exit axis rather than hanging freely. That covers a
// host attach point (a plain Node3D bolted to a device) and a plug that's held
// or socketed. A free-dangling plug is NOT fixed — it follows the rope instead.
VerletRope::EndpointRole VerletRope::ResolveEndpointRole(Node3D *node, int configured_role) const
{
    if (node == nullptr)
        return ENDPOINT_FREE_PLUG;
    if (configured_role >= ENDPOINT_HOST && configured_role <= ENDPOINT_SOCKETED_PLUG)
        return static_cast<EndpointRole>(configured_role);
    RigidBody3D *rb = Object::cast_to<RigidBody3D>(node);
    if (rb == nullptr)
        return ENDPOINT_HOST;
    if (rb->has_method("is_plugged_in") && static_cast<bool>(rb->call("is_plugged_in")))
        return ENDPOINT_SOCKETED_PLUG;
    if (rb->has_method("is_picked_up") && static_cast<bool>(rb->call("is_picked_up")))
        return ENDPOINT_HELD_PLUG;
    if (rb->is_freeze_enabled())
        return ENDPOINT_HELD_PLUG; // legacy test/tool stand-in for a held plug
    return ENDPOINT_FREE_PLUG;
}

bool VerletRope::EndpointIsFixed(EndpointRole role)
{
    return role != ENDPOINT_FREE_PLUG;
}

bool VerletRope::EndpointIsDirectional(EndpointRole role)
{
    // A host attachment is the fixed moulded end of a controller, sensor bar,
    // speaker, etc. Its authored exit axis is exactly what gives the nearby
    // segments their visible strain relief. Held plugs also carry orientation
    // authority from the player's hand. A seated plug is equally authored by
    // its socket: changing role must not make its moulded strain relief vanish.
    // Surface contacts are solved after this constraint and still keep the boot
    // out of the panel or nearby furniture.
    return role == ENDPOINT_HOST || role == ENDPOINT_HELD_PLUG ||
           role == ENDPOINT_SOCKETED_PLUG;
}

bool VerletRope::EndpointIsFree(EndpointRole role)
{
    return role == ENDPOINT_FREE_PLUG;
}

bool VerletRope::PlugIsFixed(Node3D *node) const
{
    return EndpointIsFixed(ResolveEndpointRole(node, ENDPOINT_AUTO));
}

Vector3 VerletRope::PlugExitDir(Node3D *node, const Vector3 &axis) const
{
    if (node == nullptr)
        return Vector3();
    return (node->get_global_transform().basis.orthonormalized().xform(axis)).normalized();
}

// Rotate a free plug rigidbody so its cable-exit axis points along the rope's
// tangent, easing by k per frame.
//
// The rotation is about the plug's CABLE ANCHOR, not its origin. That is what
// makes this safe to run inside the tick: the rope reads the anchor as
// transform * offset, and a real plug's offset is its cord boss some 40 mm back
// from the origin, so spinning about the origin swings the anchor through a
// 40 mm arc — it perturbs the very rope whose tangent it is chasing. This used
// to claim it "never perturbs the sim", which held only for a zero offset.
//
// Six free plugs on a composite lead made that a standing wave: each anchor
// moved ~0.7 mm a tick, over the 0.5 mm wake threshold, so the rope re-woke
// every tick forever and a cable draped on a table never stopped shivering.
void VerletRope::AlignAnchorPlug(Node3D *node, const Vector3 &offset, const Vector3 &axis,
                                 const Vector3 &target_dir_in, double k)
{
    RigidBody3D *rb = Object::cast_to<RigidBody3D>(node);
    if (rb == nullptr || rb->is_freeze_enabled())
        return;
    if (rb->has_method("is_picked_up") && static_cast<bool>(rb->call("is_picked_up")))
        return;
    if (target_dir_in.length_squared() < 1e-8)
        return;
    const Vector3 target_dir = target_dir_in.normalized();
    // We own this plug's rotation while it dangles free — kill any residual spin
    // so the physics engine doesn't drift it between our frames.
    rb->set_angular_velocity(Vector3());
    const Basis basis = rb->get_global_transform().basis.orthonormalized();
    const Vector3 cur_axis = basis.xform(axis).normalized();
    if (cur_axis.length_squared() < 1e-8)
        return;
    const double dot = CLAMP(cur_axis.dot(target_dir), -1.0, 1.0);
    if (dot > 0.9999)
        return; // already aligned
    Quaternion arc;
    if (dot < -0.9999)
    {
        // Opposite directions — pick any perpendicular for the 180 degree flip.
        Vector3 perp = cur_axis.cross(Vector3(0, 1, 0));
        if (perp.length_squared() < 1e-6)
            perp = cur_axis.cross(Vector3(1, 0, 0));
        arc = Quaternion(perp.normalized(), Math_PI);
    }
    else
    {
        arc = Quaternion(cur_axis, target_dir);
    }
    const Quaternion cur_q = basis.get_rotation_quaternion();
    const Quaternion target_q = (arc * cur_q).normalized();
    const double theta = std::acos(dot); // slerp is linear in angle, so w*theta is the applied step
    double w = CLAMP(k, 0.0, 1.0);
    if (w * theta > MAX_ALIGN_STEP)
        w = MAX_ALIGN_STEP / theta;
    const Quaternion new_q = cur_q.slerp(target_q, w);
    Transform3D xf = rb->get_global_transform();
    // Pin the anchor: work out where it is now, re-basis, then put the origin
    // back so the anchor lands in exactly the same place.
    const Vector3 anchor_before = xf.xform(offset);
    xf.basis = Basis(new_q);
    xf.origin += anchor_before - xf.xform(offset);
    rb->set_global_transform(xf);
}

// ── Tick ────────────────────────────────────────────────────────────────────

void VerletRope::_physics_process(double p_delta)
{
    Step(p_delta);
}

void VerletRope::Step(double p_delta)
{
    if (m_points.empty())
        return;
    m_step_dt_sq = std::max(p_delta * p_delta, 1e-8);

    ReconcileAnchors();

    // A socket taking a plug, or a save putting a device back where it was left,
    // moves an anchor across the room between one tick and the next. Dragging the
    // cord after it — which is what the solver does with every other kind of
    // motion — hauls the whole length through the desk and whatever is standing on
    // it, and the cord can take seconds to arrive. Lay it out afresh between the
    // anchors' new positions instead, which is where it would have been built had
    // they been in place at the time.
    if (AnchorTeleported())
    {
        InitPoints();
        return;
    }

    if (m_depen_pending)
    {
        m_depen_pending = false;
        DepenetrateLay();
    }

    if (m_asleep)
    {
        if (AnchorsMoved())
            Wake();
        else if (++m_sleep_environment_frame >= SLEEP_ENVIRONMENT_INTERVAL)
        {
            m_sleep_environment_frame = 0;
            if (EnvironmentChangedWhileSleeping())
            {
                // Edge queries can return a different face (or no face) on one
                // poll although nothing moved. Require the same conclusion on
                // two polls; a removed or intruding support persists, an
                // alternating-normal false positive does not.
                m_environment_change_polls += 1;
                if (m_environment_change_polls < 2)
                    return;
                m_environment_change_polls = 0;
                Wake();
                // The poll now discounts shallow "inside" reports already
                // explained by a valid cached plane, so a confirmed result is
                // a real removal or intrusion. Discard the old arrangement and
                // free any particles newly covered by moved furniture.
                std::fill(m_c_flags.begin(), m_c_flags.end(), 0);
                std::fill(m_mid_contact.begin(), m_mid_contact.end(), 0);
                std::fill(m_stuck_passes.begin(), m_stuck_passes.end(), 0);
                DepenetrateLay();
                m_raycast_frame = m_raycast_interval;
            }
            else
                m_environment_change_polls = 0;
        }
        if (m_asleep)
        {
            // Nothing moved, so there is nothing to interpolate between; leaving
            // this true would re-mesh a settled cable every frame forever.
            m_interpolating = false;
            return;
        }
    }
    m_mesh_dirty = true;

    Integrate(p_delta);

    // End orientation authority: a plug whose orientation is externally fixed
    // drives the ROPE. A free plug is the complement — it follows the rope (see
    // AlignAnchorPlug after the solve).
    const EndpointRole start_role = ResolveEndpointRole(m_start_cached, m_start_endpoint_role);
    const EndpointRole end_role = ResolveEndpointRole(m_end_cached, m_end_endpoint_role);
    const bool start_fixed = EndpointIsFixed(start_role);
    const bool end_fixed = EndpointIsFixed(end_role);
    const Vector3 start_exit = start_fixed ? PlugExitDir(m_start_cached, m_start_exit_axis) : Vector3();
    const Vector3 end_exit = end_fixed ? PlugExitDir(m_end_cached, m_end_exit_axis) : Vector3();
    // Hosts, held plugs and seated plugs all have authored orientation and keep
    // the moulded strain-relief stub when their endpoint role changes.
    const bool start_directional = EndpointIsDirectional(start_role);
    const bool end_directional = EndpointIsDirectional(end_role);

    SolveConstraints(start_directional, end_directional, start_exit, end_exit);
    ApplyContactFriction();

    // Cadence shared by the heavier environment queries below.
    m_raycast_frame += 1;
    const bool do_rest = m_raycast_frame >= m_raycast_interval;
    if (do_rest)
        m_raycast_frame = 0;

    // Runs every tick, not on the cadence above, despite being the only O(n^2)
    // pass here. Tried at raycast_interval and a slack cable settles visibly
    // differently: with the pushout applied on one tick in three, gravity and
    // the stretch constraints close the coils unopposed in between, and a cord
    // that should drape off a table collapses into a flat pile on it.
    if (m_self_collision)
        SolveSelfCollision();

    if (m_surface_collision_mask != 0 && m_ray_query.is_valid())
        SolveSurfaceCollision(do_rest);

    ApplyAnchorCoupling();

    // Plug end-direction alignment, FREE ends only.
    const int count = TrunkCount();
    if (m_end_align_stiffness > 0.0 && count >= 2)
    {
        if (!start_fixed)
            AlignAnchorPlug(m_start_cached, m_start_anchor_offset, m_start_exit_axis,
                            m_points[1] - m_points[0], m_end_align_stiffness);
        if (!end_fixed)
            AlignAnchorPlug(m_end_cached, m_end_anchor_offset, m_end_exit_axis,
                            m_points[count - 2] - m_points[count - 1], m_end_align_stiffness);
        for (const FrayChain &fc : m_fray)
        {
            if (fc.cached == nullptr || fc.count < 2 || PlugIsFixed(fc.cached))
                continue;
            const int last = fc.first + fc.count - 1;
            AlignAnchorPlug(fc.cached, fc.offset, m_end_exit_axis,
                            m_points[last - 1] - m_points[last],
                            m_end_align_stiffness);
        }
    }

    UpdateSleepState();
    // Last thing in the tick, after the anchors are pinned: roll the render
    // history forward so _process has two states to interpolate between.
    SnapshotRenderState();
}

void VerletRope::Integrate(double p_delta)
{
    const int count = static_cast<int>(m_points.size());
    const Vector3 grav_step = m_gravity * (p_delta * p_delta);
    const double retain = 1.0 - m_damping;
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f)
            continue;
        const Vector3 current = m_points[i];
        const Vector3 velocity = (current - m_prev_points[i]) * retain;
        m_prev_points[i] = current;
        m_points[i] = current + velocity + grav_step;
    }
    PinAnchors();
}

void VerletRope::SolveConstraints(bool p_start_fixed, bool p_end_fixed,
                                  const Vector3 &p_start_exit, const Vector3 &p_end_exit)
{
    // The trunk's own particle range. Without a fray this is every particle, so
    // all the loops below are exactly what they were.
    const int count = TrunkCount();
    const int seg_count = static_cast<int>(m_seg_a.size());
    const int iters = m_constraint_iterations > 1 ? m_constraint_iterations : 1;
    m_stretch_lambda.assign(seg_count, 0.0);
    m_mid_contact_lambda.assign(seg_count, 0.0);
    m_mid_contact_lambda_2.assign(seg_count, 0.0);
    m_contact_lambda_1.assign(m_points.size(), 0.0);
    m_contact_lambda_2.assign(m_points.size(), 0.0);
    m_bend_lambda.clear();
    m_angle_lambda.clear();

    // Stretch stiffness is remapped so extensibility is independent of the
    // iteration count (k' = 1-(1-k)^(1/n)); 1.0 stays fully rigid.
    const double k_stretch = 1.0 - std::pow(1.0 - CLAMP(m_stretch_stiffness, 0.0, 1.0), 1.0 / iters);
    // Bend stiffness is applied directly per iteration — remapping it the same
    // way crushes mid-range values into "floppy" at typical iteration counts.
    const double k_bend = CLAMP(m_bend_stiffness, 0.0, 1.0);
    // Angular projection is stronger than the old midpoint displacement for
    // the same numeric rating. Preserve the authored cable feel while making
    // the value iteration-count independent.
    // A bend of angle B deviates the particle L*sin(B/2) from the midpoint;
    // bends up to max_bend_degrees are free.
    const double allowed_dev = m_segment_length * std::sin(Math::deg_to_rad(m_max_bend_degrees) * 0.5);

    // Contact flags are only rewritten by the throttled rest pass, never inside
    // the solve, so gather the active planes once instead of re-testing every
    // particle on all eight iterations.
    m_active_mid.clear();
    for (int s = 0; s < seg_count; ++s)
        if (m_mid_contact[s] != 0)
            m_active_mid.push_back(s);
    m_active_contact.clear();
    for (int i = 0, n = static_cast<int>(m_points.size()); i < n; ++i)
        if (m_inv_mass[i] != 0.0f && m_c_flags[i] != 0)
            m_active_contact.push_back(i);

    for (int iter_i = 0; iter_i < iters; ++iter_i)
    {
        // Stretch runs off the segment table, so a branch's link back to the
        // junction is solved with the rest, at the branch's own rest length.
        for (int s = 0; s < seg_count; ++s)
            SolvePair(m_seg_a[s], m_seg_b[s], m_seg_rest[s], k_stretch,
                      m_stretch_compliance > 0.0 ? &m_stretch_lambda[s] : nullptr);

        // Bend, hierarchical: adjacent midpoint bending preserves the existing
        // cable drape, while spacing 2/4/8 keeps long ropes from saturating.
        if (k_bend > 0.0)
        {
            int levels = 1 + static_cast<int>(std::lround(k_bend * 3.0));
            int s = 1;
            while (s * 2 <= count - 1 && levels > 0)
            {
                const double allowed = allowed_dev * static_cast<double>(s * s);
                if (iter_i % 2 == 0)
                    for (int i = s; i < count - s; ++i)
                        SolveBend(i, s, allowed, k_bend);
                else
                    for (int i = count - s - 1; i >= s; --i)
                        SolveBend(i, s, allowed, k_bend);
                s *= 2;
                levels -= 1;
            }
        }

        // End stiffness (strain-relief boot): hold the first/last few segments
        // perfectly straight with a strong direct stiffness, so the cable
        // emerges rigid from each plug and only bends past the stub. Applied
        // after the general bend so it wins near the ends.
        if (m_end_stiffness > 0.0 && m_end_stiff_segments > 0)
        {
            const double ke = CLAMP(m_end_stiffness, 0.0, 1.0);
            const int n_end = std::min(m_end_stiff_segments, (count - 1) / 2);
            if (iter_i % 2 == 0)
            {
                for (int i = 1; i <= n_end; ++i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, i, n_end));
                for (int i = count - 2; i > count - 2 - n_end; --i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, count - 1 - i, n_end));
            }
            else
            {
                for (int i = n_end; i >= 1; --i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, i, n_end));
                for (int i = count - 1 - n_end; i < count - 1; ++i)
                    SolveBend(i, 1, 0.0, StubWeight(ke, count - 1 - i, n_end));
            }
        }

        // Adjacent segments cannot self-collide. Only in the severe-fold region
        // add nonlinear angular resistance and the hard per-joint limit.
        if (k_bend > 0.0 || m_bend_limit_degrees < 180.0)
        {
            if (iter_i % 2 == 0)
                for (int i = 1; i < count - 1; ++i)
                    SolveAngleBend(i - 1, i, i + 1, 0.0, k_bend);
            else
                for (int i = count - 2; i >= 1; --i)
                    SolveAngleBend(i - 1, i, i + 1, 0.0, k_bend);
        }

        // Directional strain-relief stub: pull the first/last few particles
        // onto the authored exit line of a host, held plug or seated plug.
        if (m_end_stiffness > 0.0 && m_end_stiff_segments > 0 &&
            (p_start_fixed || p_end_fixed))
        {
            const double ked = CLAMP(m_end_stiffness, 0.0, 1.0);
            const int nd = std::min(m_end_stiff_segments, (count - 1) / 2);
            if (p_end_fixed)
            {
                const Vector3 base_e = m_points[count - 1];
                for (int j = 1; j <= nd; ++j)
                {
                    const int idx = count - 1 - j;
                    if (m_inv_mass[idx] != 0.0f)
                        m_points[idx] = m_points[idx].lerp(
                            base_e + p_end_exit * (m_segment_length * j),
                            StubWeight(ked, j, nd));
                }
            }
            if (p_start_fixed)
            {
                const Vector3 base_s = m_points[0];
                for (int j = 1; j <= nd; ++j)
                {
                    if (m_inv_mass[j] != 0.0f)
                        m_points[j] = m_points[j].lerp(
                            base_s + p_start_exit * (m_segment_length * j),
                            StubWeight(ked, j, nd));
                }
            }
        }

        if (!m_fray.empty())
            SolveFrayConstraints(iter_i, k_stretch, k_bend, allowed_dev);

        // Cached contact planes, solved together with the other constraints so
        // contacts — including edge wraps — are part of the equilibrium instead
        // of oscillating.
        for (int s : m_active_mid)
        {
            if (m_mid_contact[s] & 1)
                SolveMidContact(s, false);
            if (m_mid_contact[s] & 2)
                SolveMidContact(s, true);
        }
        for (int i : m_active_contact)
        {
            const uint8_t flags = m_c_flags[i];
            if (flags & 1)
                ProjectPlane(i, m_c_p1[i], m_c_n1[i], m_contact_lambda_1[i]);
            if (flags & 2)
                ProjectPlane(i, m_c_p2[i], m_c_n2[i], m_contact_lambda_2[i]);
        }
        PinAnchors();
    }
}

// Bend and stub constraints for the frayed branches. Stretch is not here — it
// comes off the shared segment table with the trunk's.
//
// A branch gets a strain-relief boot at BOTH ends, the plug and the breakout.
// The breakout one matters more than it sounds: a moulded fray is stiff where
// the cords leave it, so they carry the trunk's direction out for a few
// centimetres and curve away under their own weight. Left as a free hinge — which
// this deliberately was, on the reasoning that a fray point is a hinge — gravity
// turns every cord vertically downward the instant it separates, and the fray
// reads as three wires dropped out of a hole rather than a moulded breakout.
void VerletRope::SolveFrayConstraints(int p_iter, double, double p_k_bend, double p_allowed_dev)
{
    const double seg_len = FraySegLength();
    for (const FrayChain &fc : m_fray)
    {
        const int first = fc.first;
        const int last = fc.first + fc.count - 1;
        if (fc.count < 3)
            continue;

        if (p_k_bend > 0.0)
        {
            int levels = 1 + static_cast<int>(std::lround(p_k_bend * 3.0));
            int s = 1;
            while (s * 2 <= fc.count - 1 && levels > 0)
            {
                const double allowed = p_allowed_dev * static_cast<double>(s * s);
                if (p_iter % 2 == 0)
                    for (int i = first + s; i <= last - s; ++i)
                        SolveBend(i, s, allowed, p_k_bend);
                else
                    for (int i = last - s; i >= first + s; --i)
                        SolveBend(i, s, allowed, p_k_bend);
                // `first` sits one short of that range at every spacing, and its
                // low neighbour is the junction — a different chain, so the
                // spacing form cannot reach it. It is picked up by the breakout
                // boot below instead of here: adding it at every iteration piles
                // a second constraint per branch onto the junction, and with
                // three branches that fight was enough to stop a lead settling
                // on a table edge (asleep 107/200 of the tail, down to 34).
                s *= 2;
                levels -= 1;
            }
        }

        if (p_k_bend > 0.0 || m_bend_limit_degrees < 180.0)
        {
            if (p_iter % 2 == 0)
                for (int i = first + 1; i < last; ++i)
                    SolveAngleBend(i - 1, i, i + 1, 0.0, p_k_bend);
            else
                for (int i = last - 1; i > first; --i)
                    SolveAngleBend(i - 1, i, i + 1, 0.0, p_k_bend);
        }

        // Strain-relief boot at the plug, the same taper the trunk's ends get.
        if (m_end_stiffness > 0.0 && m_end_stiff_segments > 0)
        {
            const double ke = CLAMP(m_end_stiffness, 0.0, 1.0);
            const int n_end = std::min(m_end_stiff_segments, fc.count - 2);
            for (int j = 1; j <= n_end; ++j)
                SolveBend(last - j, 1, 0.0, StubWeight(ke, j, n_end));

            // …and at the breakout. The first triple spans the junction, holding
            // the branch on the line the trunk arrives along; the rest taper it
            // off into the branch exactly as the plug's boot does.
            const int trunk_n = TrunkCount();
            const int trunk_prev = fc.at_start ? 1 : trunk_n - 2;
            const int n_head = std::min(m_end_stiff_segments, fc.count - 1);
            if (trunk_n >= 2 && n_head > 0)
            {
                // Two triples, not one. The first holds the JUNCTION straight
                // between the trunk and the branch; the second holds the
                // branch's first particle, whose low neighbour is that junction
                // and so is out of reach of the contiguous form below.
                SolveBendTriple(trunk_prev, fc.head, first, 0.0, StubWeight(ke, 1, n_head));
                SolveBendAnchored(fc.head, first, first + 1, StubWeight(ke, 1, n_head));
                for (int j = 1; j < n_head; ++j)
                    SolveBend(first + j, 1, 0.0, StubWeight(ke, j + 1, n_head));
            }

            // Directional stub: a branch whose plug is held or socketed leaves
            // it along the plug's exit axis rather than hanging off it.
            if (PlugIsFixed(fc.cached))
            {
                const Vector3 exit = PlugExitDir(fc.cached, m_end_exit_axis);
                const Vector3 base = m_points[last];
                for (int j = 1; j <= n_end; ++j)
                {
                    const int idx = last - j;
                    if (m_inv_mass[idx] != 0.0f)
                        m_points[idx] = m_points[idx].lerp(base + exit * (seg_len * j),
                                                           StubWeight(ke, j, n_end));
                }
            }
        }
    }
}

// Friction for cached resting contacts (once per frame, not per iteration): damp
// the tangential velocity of every particle a contact plane is holding.
void VerletRope::ApplyContactFriction()
{
    const int count = static_cast<int>(m_points.size());
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f || m_c_flags[i] == 0)
            continue;
        for (int slot = 0; slot < 2; ++slot)
        {
            if ((m_c_flags[i] & (1 << slot)) == 0)
                continue;
            const Vector3 n = slot == 0 ? m_c_n1[i] : m_c_n2[i];
            const Vector3 cp = slot == 0 ? m_c_p1[i] : m_c_p2[i];
            if ((m_points[i] - cp).dot(n) > m_collision_radius * 1.05)
                continue;
            const Vector3 vel = m_points[i] - m_prev_points[i];
            const Vector3 tangential = vel - n * vel.dot(n);
            m_prev_points[i] = m_points[i] - tangential * (1.0 - m_surface_friction);
        }
    }
}

bool VerletRope::EnvironmentChangedWhileSleeping()
{
    if (m_surface_collision_mask == 0 || m_shape_query.is_null())
        return false;
    Ref<World3D> world = get_world_3d();
    if (world.is_null())
        return false;
    PhysicsDirectSpaceState3D *space_state = world->get_direct_space_state();
    if (space_state == nullptr)
        return false;

    const auto point_inside = [this, space_state](const Vector3 &p) {
        if (m_point_query.is_null())
            return true;
        m_point_query->set_position(p);
        return !space_state->intersect_point(m_point_query, 1).is_empty();
    };
    const auto cached_surface_exists = [this, space_state](const Vector3 &p,
                                                           const Vector3 &cached_p,
                                                           const Vector3 &cached_n) {
        if (m_ray_query.is_null() || cached_n == Vector3())
            return false;
        const double probe = m_collision_radius * 3.0;
        m_ray_query->set_from(p + cached_n * probe);
        m_ray_query->set_to(p - cached_n * probe);
        const Dictionary hit = space_state->intersect_ray(m_ray_query);
        if (hit.is_empty())
            return false;
        const Vector3 n = hit["normal"];
        const Vector3 hp = hit["position"];
        return n.dot(cached_n) > 0.85 &&
               std::abs((hp - cached_p).dot(cached_n)) <= m_collision_radius;
    };

    const int count = static_cast<int>(m_points.size());
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f)
            continue;
        // Capsule contacts below are the authoritative support test. Particle
        // planes are only local solver manifold slots and can legitimately go
        // stale as an edge hands support to the adjacent segment. Their one
        // reliable environmental signal is a collider newly covering the
        // stationary centre.
        if (point_inside(m_points[i]))
        {
            const bool cached_valid =
                ((m_c_flags[i] & 1) && PlaneValid(i, m_c_p1[i], m_c_n1[i])) ||
                ((m_c_flags[i] & 2) && PlaneValid(i, m_c_p2[i], m_c_n2[i]));
            if (!cached_valid)
                return true;
        }
    }

    const int seg_count = static_cast<int>(m_seg_a.size());
    for (int s = 0; s < seg_count; ++s)
    {
        const int a = m_seg_a[s];
        const int b = m_seg_b[s];
        if (m_inv_mass[a] + m_inv_mass[b] == 0.0f)
            continue;
        // A capsule-only hit may lie anywhere along the segment. Poll that
        // cached coordinate, not always the midpoint: on a thin plate the
        // midpoint can be in open air while the segment is legitimately held
        // near one end. Two false midpoint misses used to wake a settled cable,
        // clear its valid manifold and let it fall through the plate.
        const Vector3 sample = (m_mid_contact[s] & 1)
                                   ? m_points[a].lerp(m_points[b], m_mid_contact_t[s])
                                   : (m_points[a] + m_points[b]) * 0.5;
        m_shape_query->set_transform(Transform3D(Basis(), sample));
        const Dictionary rest = space_state->get_rest_info(m_shape_query);
        const bool has = !rest.is_empty() && rest["normal"].operator Vector3() != Vector3();
        const bool had = m_mid_contact[s] != 0;
        if (point_inside(sample) && !had)
            return true;
        if (had)
        {
            if (has)
                continue;
            bool surface_still_there =
                (m_mid_contact[s] & 1) &&
                cached_surface_exists(sample, m_mid_contact_point[s], m_mid_contact_normal[s]);
            if (!surface_still_there && (m_mid_contact[s] & 2))
            {
                const Vector3 sample2 = m_points[a].lerp(m_points[b], m_mid_contact_t_2[s]);
                surface_still_there = cached_surface_exists(
                    sample2, m_mid_contact_point_2[s], m_mid_contact_normal_2[s]);
            }
            if (surface_still_there)
                continue;
            return true;
        }
        (void)has;
    }
    return false;
}

void VerletRope::SolveSelfCollision()
{
    const int count = static_cast<int>(m_points.size());
    const double min_d = m_collision_radius * 2.0;
    const double min_d_sq = min_d * min_d;
    for (int i = 0; i < count; ++i)
    {
        const float w_i = m_inv_mass[i];
        const uint8_t g_i = m_self_group[i];
        Vector3 p_i = m_points[i];
        // j >= i+2 exempts chain neighbours by ARRAY distance, which stops being
        // chain distance once branches are appended: a branch's head and the
        // trunk's end are coincident but far apart in the array, as are the
        // heads of two branches. m_self_group re-states that by construction.
        for (int j = i + 2; j < count; ++j)
        {
            const float w_j = m_inv_mass[j];
            const float w_sum = w_i + w_j;
            if (w_sum == 0.0f)
                continue;
            if (g_i != 0 && g_i == m_self_group[j])
                continue;
            const Vector3 diff = m_points[j] - p_i;
            const double d_sq = diff.length_squared();
            if (d_sq >= min_d_sq || d_sq < 1e-8)
                continue;
            const double dist = std::sqrt(d_sq);
            const Vector3 push = diff * ((dist - min_d) / dist);
            p_i += push * (w_i / w_sum);
            m_points[j] -= push * (w_j / w_sum);
        }
        m_points[i] = p_i;
    }

    // Particle pairs do not see two long segments crossing at their middles:
    // every endpoint can be centimetres clear while the rendered tubes pass
    // straight through each other. Work from the real segment table so fray
    // chain boundaries are topological rather than accidental array adjacency.
    const int seg_count = static_cast<int>(m_seg_a.size());
    bool segment_corrected = false;
    for (int sa = 0; sa < seg_count; ++sa)
    {
        const int a0 = m_seg_a[sa];
        const int a1 = m_seg_b[sa];
        for (int sb = sa + 1; sb < seg_count; ++sb)
        {
            const int b0 = m_seg_a[sb];
            const int b1 = m_seg_b[sb];
            if (a0 == b0 || a0 == b1 || a1 == b0 || a1 == b1)
                continue; // neighbours joined by construction

            // The first particles around one fray junction deliberately overlap
            // inside the moulded breakout. Preserve the same exemption the point
            // solver uses for that shared construction volume.
            bool construction_pair = false;
            const int ae[2] = {a0, a1};
            const int be[2] = {b0, b1};
            for (int ai = 0; ai < 2 && !construction_pair; ++ai)
                for (int bi = 0; bi < 2; ++bi)
                    if (m_self_group[ae[ai]] != 0 && m_self_group[ae[ai]] == m_self_group[be[bi]])
                    {
                        construction_pair = true;
                        break;
                    }
            if (construction_pair)
                continue;

            const Vector3 p0 = m_points[a0];
            const Vector3 p1 = m_points[a1];
            const Vector3 q0 = m_points[b0];
            const Vector3 q1 = m_points[b1];
            const Vector3 u = p1 - p0;
            const Vector3 v = q1 - q0;
            const Vector3 w = p0 - q0;
            const double uu = u.dot(u);
            const double uv = u.dot(v);
            const double vv = v.dot(v);
            const double uw = u.dot(w);
            const double vw = v.dot(w);
            const double denom = uu * vv - uv * uv;
            if (uu < 1e-12 || vv < 1e-12)
                continue;

            // Only interior/interior contacts belong to this pass, so the
            // unclamped closest points on the two supporting lines are enough.
            // Endpoint cases are deliberately left to particle collision below.
            if (denom < 1e-12)
                continue;
            const double s = (uv * vw - vv * uw) / denom;
            const double t = (uu * vw - uv * uw) / denom;
            // Endpoint-near contact is already covered by the particle pass.
            // Solving it again as a segment pair over-inflates tight coils and
            // makes a shortened rope appear longer. This pass exists for the
            // blind spot particle collision cannot see: interior crossings.
            constexpr double INTERIOR_EPS = 0.05;
            if (s <= INTERIOR_EPS || s >= 1.0 - INTERIOR_EPS ||
                t <= INTERIOR_EPS || t >= 1.0 - INTERIOR_EPS)
                continue;
            const Vector3 cp = p0 + u * s;
            const Vector3 cq = q0 + v * t;
            Vector3 diff = cq - cp;
            double dist = diff.length();
            // Leave a small dead band at contact. Correcting numerical dust on
            // two already-separated strands every tick can keep a draped lead
            // awake indefinitely.
            if (dist >= min_d * 0.9)
                continue;

            Vector3 n;
            if (dist > min_d * 0.01)
                n = diff / dist;
            else
            {
                n = u.cross(v);
                if (n.length_squared() < 1e-12)
                {
                    const Vector3 ref = std::abs(u.normalized().dot(Vector3(0, 1, 0))) < 0.9
                                            ? Vector3(0, 1, 0)
                                            : Vector3(1, 0, 0);
                    n = u.cross(ref);
                }
                n = n.normalized();
                dist = 0.0;
            }

            const double as0 = 1.0 - s;
            const double as1 = s;
            const double bt0 = 1.0 - t;
            const double bt1 = t;
            const double weight = m_inv_mass[a0] * as0 * as0 + m_inv_mass[a1] * as1 * as1 +
                                  m_inv_mass[b0] * bt0 * bt0 + m_inv_mass[b1] * bt1 * bt1;
            if (weight <= 0.0)
                continue;
            const double lambda = (min_d - dist) / weight;
            const Vector3 da0 = -n * (lambda * m_inv_mass[a0] * as0);
            const Vector3 da1 = -n * (lambda * m_inv_mass[a1] * as1);
            const Vector3 db0 = n * (lambda * m_inv_mass[b0] * bt0);
            const Vector3 db1 = n * (lambda * m_inv_mass[b1] * bt1);
            m_points[a0] += da0;
            m_points[a1] += da1;
            m_points[b0] += db0;
            m_points[b1] += db1;
            // A positional collision correction is not a launch impulse. Move
            // Verlet history with it so the separated strands do not inherit
            // the correction as velocity on the next tick.
            m_prev_points[a0] += da0;
            m_prev_points[a1] += da1;
            m_prev_points[b0] += db0;
            m_prev_points[b1] += db1;
            segment_corrected = true;
        }
    }
    // Collision is applied after the main constraint solve. Restore the length
    // it may have borrowed in order to part a crossing, otherwise a hard yank
    // can leave one segment just beyond the established recovery bound.
    if (segment_corrected && m_stretch_stiffness > 0.0)
    {
        const double k = CLAMP(m_stretch_stiffness, 0.0, 1.0);
        for (int s = 0; s < seg_count; ++s)
            SolvePair(m_seg_a[s], m_seg_b[s], m_seg_rest[s], k);
        PinAnchors();
    }
}

// Which slot a freshly reported plane belongs in. The cascade is ordered by how
// much the new normal agrees with what is already cached: an almost-exact match
// refreshes that slot, a loose match (a cord sliding over a curved surface)
// still refreshes it rather than banking a second nearly-parallel plane, which
// would pinch the particle as if the smooth pipe were a sharp corner. Only once
// neither cached plane can claim it does an empty slot take it.
//
// Returning 0 is a real outcome, not a fallthrough: when BOTH slots are valid
// and neither normal matches, the stable two-plane manifold of a genuine edge
// is kept and the new plane is dropped.
int VerletRope::ChooseContactSlot(int i, const Vector3 &p_point, const Vector3 &p_normal,
                                  bool p_keep1, bool p_keep2) const
{
    const double d1 = p_normal.dot(m_c_n1[i]);
    const double d2 = p_normal.dot(m_c_n2[i]);
    if (p_keep1 && d1 > 0.9)
        return 1;
    if (p_keep2 && d2 > 0.9)
        return 2;
    if (p_keep1 && d1 > 0.5)
        return 1;
    if (p_keep2 && d2 > 0.5)
        return 2;
    if (!p_keep1)
        return 1;
    if (!p_keep2)
    {
        // A second plane is for a real edge, so it has to be near the first.
        // A distant one is a different surface: overwrite slot 1 instead of
        // banking a manifold spanning two places the cord cannot touch at once.
        return p_point.distance_to(m_c_p1[i]) < m_collision_radius * 3.0 ? 2 : 1;
    }
    return 0;
}


// Write a plane into a slot. Occupying a slot always validates it, including
// the arms that overwrite one that was already valid.
void VerletRope::AssignContactSlot(int i, int p_slot, const Vector3 &p_point,
                                   const Vector3 &p_normal, bool &r_keep1, bool &r_keep2)
{
    if (p_slot == 1)
    {
        m_c_p1[i] = p_point;
        m_c_n1[i] = p_normal;
        r_keep1 = true;
    }
    else if (p_slot == 2)
    {
        m_c_p2[i] = p_point;
        m_c_n2[i] = p_normal;
        r_keep2 = true;
    }
}


void VerletRope::SolveSurfaceCollision(bool p_do_rest)
{
    Ref<World3D> world = get_world_3d();
    if (world.is_null())
        return;
    PhysicsDirectSpaceState3D *space_state = world->get_direct_space_state();
    if (space_state == nullptr)
        return;

    SweepParticleContacts(space_state, p_do_rest);
    SolveSegmentCollision(space_state, p_do_rest);
    if (p_do_rest)
        RecoverWrongSideParticles(space_state);
}


// Phase one: each particle's own motion sweep, and its cached contact planes.
void VerletRope::SweepParticleContacts(PhysicsDirectSpaceState3D *space_state, bool p_do_rest)
{
    const int count = static_cast<int>(m_points.size());
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f)
            continue;
        // Sweep this frame's motion so a point can't tunnel through thin
        // geometry, even between rest-query frames.
        const Vector3 from = m_prev_points[i];
        const Vector3 to = m_points[i];
        const Vector3 motion = to - from;
        if (motion.length_squared() > 0.000001)
        {
            m_ray_query->set_from(from);
            m_ray_query->set_to(to + motion.normalized() * m_collision_radius);
            Dictionary hit = space_state->intersect_ray(m_ray_query);
            if (!hit.is_empty())
            {
                const Vector3 hit_normal = hit["normal"];
                if (hit_normal != Vector3())
                {
                    ResolveContact(i, hit["position"], hit_normal);
                    m_c_flags[i] |= 1;
                    m_c_p1[i] = hit["position"];
                    m_c_n1[i] = hit_normal;
                    continue;
                }
            }
        }
        // Resting contact (throttled — heavier query): refresh the particle's
        // cached contact-plane manifold. The planes are enforced every frame
        // INSIDE the constraint loop, so contacts are part of the solver's
        // equilibrium; snapping the particle here instead fights the other
        // constraints and jitters edge wraps. The query only reports the deepest
        // plane (which alternates at a corner), so a still-valid previous plane
        // with a different normal is kept as a second slot.
        if (p_do_rest)
        {
            m_shape_query->set_transform(Transform3D(Basis(), m_points[i]));
            Dictionary rest = space_state->get_rest_info(m_shape_query);
            bool keep1 = (m_c_flags[i] & 1) != 0 && PlaneValid(i, m_c_p1[i], m_c_n1[i]);
            bool keep2 = (m_c_flags[i] & 2) != 0 && PlaneValid(i, m_c_p2[i], m_c_n2[i]);
            // Deep-penetration guard: if the particle centre is BEHIND the
            // reported plane it has passed the surface, and ejecting along this
            // normal can pop it out the FAR side of a slab. Don't cache — the
            // wrong-side recovery below walks it back instead.
            if (!rest.is_empty())
            {
                const Vector3 nn = rest["normal"];
                const Vector3 np = rest["point"];
                if (nn != Vector3() && (m_points[i] - np).dot(nn) >= 0.0)
                    AssignContactSlot(i, ChooseContactSlot(i, np, nn, keep1, keep2), np, nn,
                                      keep1, keep2);
            }
            m_c_flags[i] = static_cast<uint8_t>((keep1 ? 1 : 0) | (keep2 ? 2 : 0));
        }
    }

}


// Phase two: whole-segment capsule collision. Point rays miss an obstacle
// whenever both particles clear it but the jacket between them does not.
// Translation is swept every tick; the final, rotated capsule is sampled on the
// resting contact cadence. The resulting point along the segment is constrained
// in the same iterative solve as stretch and bend.
void VerletRope::SolveSegmentCollision(PhysicsDirectSpaceState3D *space_state, bool p_do_rest)
{
    const int seg_count = static_cast<int>(m_seg_a.size());
    const auto set_capsule = [&](const Vector3 &a, const Vector3 &b) {
        const Vector3 segment = b - a;
        const double length = segment.length();
        Basis basis;
        if (length > 1e-8)
            basis = Basis(Quaternion(Vector3(0, 1, 0), segment / length));
        m_segment_capsule->set_height(static_cast<float>(length + m_collision_radius * 2.6));
        return Transform3D(basis, (a + b) * 0.5);
    };
    const auto cache_segment_hit = [&](int s, const Dictionary &rest) {
        if (rest.is_empty())
            return false;
        const Vector3 n = rest["normal"];
        if (n == Vector3())
            return false;
        const int ia = m_seg_a[s];
        const int ib = m_seg_b[s];
        const Vector3 segment = m_points[ib] - m_points[ia];
        const double length_sq = segment.length_squared();
        const Vector3 point = rest["point"];
        double t = length_sq > 1e-10
                       ? CLAMP((point - m_points[ia]).dot(segment) / length_sq, 0.0, 1.0)
                       : 0.5;
        const auto slot_valid = [&](bool second) {
            const float old_t = second ? m_mid_contact_t_2[s] : m_mid_contact_t[s];
            const Vector3 &old_point = second ? m_mid_contact_point_2[s] : m_mid_contact_point[s];
            const Vector3 &old_normal = second ? m_mid_contact_normal_2[s] : m_mid_contact_normal[s];
            const Vector3 old_sample = m_points[ia].lerp(m_points[ib], old_t);
            return old_sample.distance_squared_to(old_point) <=
                       m_seg_rest[s] * m_seg_rest[s] * 4.0 &&
                   std::abs((old_sample - old_point).dot(old_normal)) <
                       m_collision_radius * 3.0;
        };
        if ((m_mid_contact[s] & 1) && !slot_valid(false))
            m_mid_contact[s] &= ~1;
        if ((m_mid_contact[s] & 2) && !slot_valid(true))
            m_mid_contact[s] &= ~2;

        bool second = false;
        if ((m_mid_contact[s] & 1) && n.dot(m_mid_contact_normal[s]) > 0.9)
            t = m_mid_contact_t[s];
        else if ((m_mid_contact[s] & 2) && n.dot(m_mid_contact_normal_2[s]) > 0.9)
        {
            second = true;
            t = m_mid_contact_t_2[s];
        }
        else if ((m_mid_contact[s] & 1) == 0)
            second = false;
        else if ((m_mid_contact[s] & 2) == 0)
        {
            // Two simultaneous planes are for a real sharp edge. A curved pipe
            // also changes normal as the contact coordinate slides, but keeping
            // both nearby tangents pinches the segment and creates chatter.
            second = std::abs(n.dot(m_mid_contact_normal[s])) < 0.2 &&
                     point.distance_to(m_mid_contact_point[s]) < m_collision_radius;
        }
        else
            return true; // both edge faces remain valid; keep the stable manifold

        const Vector3 centreline = m_points[ia].lerp(m_points[ib], t);
        if (-(centreline - point).dot(n) > m_collision_radius * 3.0)
            return false;
        if (second)
        {
            m_mid_contact[s] |= 2;
            m_mid_contact_point_2[s] = point;
            m_mid_contact_normal_2[s] = n;
            m_mid_contact_t_2[s] = static_cast<float>(t);
        }
        else
        {
            m_mid_contact[s] |= 1;
            m_mid_contact_point[s] = point;
            m_mid_contact_normal[s] = n;
            m_mid_contact_t[s] = static_cast<float>(t);
        }
        return true;
    };
    for (int s = 0; s < seg_count; ++s)
    {
        const int ia = m_seg_a[s];
        const int ib = m_seg_b[s];
        if (m_inv_mass[ia] + m_inv_mass[ib] == 0.0f)
            continue;
        const Vector3 previous_mid = (m_prev_points[ia] + m_prev_points[ib]) * 0.5;
        const Vector3 current_mid = (m_points[ia] + m_points[ib]) * 0.5;
        const Vector3 motion = current_mid - previous_mid;
        const double capsule_sweep_threshold = m_collision_radius * 4.0;
        if (m_mid_contact[s] == 0 &&
            motion.length_squared() > capsule_sweep_threshold * capsule_sweep_threshold)
        {
            m_segment_shape_query->set_transform(set_capsule(m_prev_points[ia], m_prev_points[ib]));
            m_segment_shape_query->set_motion(Vector3());
            const bool already_touching =
                !space_state->get_rest_info(m_segment_shape_query).is_empty();
            if (!already_touching)
            {
                m_segment_shape_query->set_motion(motion);
                const PackedFloat32Array fractions = space_state->cast_motion(m_segment_shape_query);
                if (fractions.size() >= 2 && fractions[0] < 1.0f)
                {
                    const double safe = fractions[0];
                    const double unsafe = fractions[1];
                    const Vector3 wanted_a = m_points[ia];
                    const Vector3 wanted_b = m_points[ib];
                    const Vector3 hit_a = m_prev_points[ia].lerp(wanted_a, unsafe);
                    const Vector3 hit_b = m_prev_points[ib].lerp(wanted_b, unsafe);
                    m_segment_shape_query->set_transform(set_capsule(hit_a, hit_b));
                    m_segment_shape_query->set_motion(Vector3());
                    Dictionary hit = space_state->get_rest_info(m_segment_shape_query);
                    if (!hit.is_empty() && hit["normal"].operator Vector3() != Vector3())
                    {
                        const Vector3 hit_segment = hit_b - hit_a;
                        const double hit_length_sq = hit_segment.length_squared();
                        const Vector3 hit_point = hit["point"];
                        const double t = hit_length_sq > 1e-10
                                             ? CLAMP((hit_point - hit_a).dot(hit_segment) /
                                                         hit_length_sq,
                                                     0.0, 1.0)
                                             : 0.5;
                        const Vector3 safe_a = m_prev_points[ia].lerp(wanted_a, safe);
                        const Vector3 safe_b = m_prev_points[ib].lerp(wanted_b, safe);
                        const Vector3 correction = safe_a.lerp(safe_b, t) -
                                                   wanted_a.lerp(wanted_b, t);
                        const double ta = 1.0 - t;
                        const double weight = m_inv_mass[ia] * ta * ta +
                                              m_inv_mass[ib] * t * t;
                        if (weight > 0.0)
                        {
                            const Vector3 da = correction * (m_inv_mass[ia] * ta / weight);
                            const Vector3 db = correction * (m_inv_mass[ib] * t / weight);
                            m_points[ia] += da;
                            m_points[ib] += db;
                            m_prev_points[ia] += da;
                            m_prev_points[ib] += db;
                            // Zero the contact point's inward normal velocity.
                            // Preserving it makes the same swept segment strike
                            // the edge again next tick and pumps a pendulum mode.
                            const Vector3 normal = hit["normal"];
                            const Vector3 contact_velocity =
                                m_points[ia].lerp(m_points[ib], t) -
                                m_prev_points[ia].lerp(m_prev_points[ib], t);
                            const double normal_velocity = contact_velocity.dot(normal);
                            if (normal_velocity < 0.0)
                            {
                                const Vector3 stop = normal * normal_velocity;
                                m_prev_points[ia] += stop * (m_inv_mass[ia] * ta / weight);
                                m_prev_points[ib] += stop * (m_inv_mass[ib] * t / weight);
                            }
                        }
                        cache_segment_hit(s, hit);
                    }
                }
            }
        }
        if (p_do_rest)
        {
            // Prefer the finite midpoint sphere on broad resting surfaces: a
            // full capsule has infinitely many equally deep contacts there and
            // the engine may hand back a different coordinate every refresh.
            // Fall back to the capsule only for its actual blind spot — an
            // obstacle intersecting the segment away from its midpoint.
            const Vector3 midpoint = (m_points[ia] + m_points[ib]) * 0.5;
            m_shape_query->set_transform(Transform3D(Basis(), midpoint));
            const Dictionary midpoint_rest = space_state->get_rest_info(m_shape_query);
            if (!midpoint_rest.is_empty())
            {
                // A finite midpoint sphere owns one contact coordinate. Replace
                // its plane as a smooth surface turns; two planes here would
                // pinch a cord on a pipe. The two-slot manifold is reserved for
                // capsule-only edge contacts away from the midpoint.
                m_mid_contact[s] = 0;
                if (cache_segment_hit(s, midpoint_rest))
                    m_mid_contact_t[s] = 0.5f;
            }
            else
            {
                m_segment_shape_query->set_transform(set_capsule(m_points[ia], m_points[ib]));
                m_segment_shape_query->set_motion(Vector3());
                if (!cache_segment_hit(s, space_state->get_rest_info(m_segment_shape_query)))
                    m_mid_contact[s] = 0;
            }
        }
    }

}


// Phase three: wrong-side recovery. A particle that tunnelled through a slab
// gets locked on the far side — every time the stretch constraints pull it
// back, the motion sweep hits the slab's far face front-on and re-strands it,
// so the state is self-sustaining. Local contact info can't detect this;
// CONNECTIVITY can: cast the segment ray BOTH ways. A segment genuinely
// passing through a slab enters one face and exits through an opposing face
// (normals antiparallel), while a legit drape over an edge crosses roughly
// perpendicular faces. Require the state on two consecutive rest passes, then
// teleport the particle back to the entry face.
//
// Rest passes only — the caller gates it.
void VerletRope::RecoverWrongSideParticles(PhysicsDirectSpaceState3D *space_state)
{
    const int seg_count = static_cast<int>(m_seg_a.size());
    for (int s = 0; s < seg_count; ++s)
    {
        const int prev = m_seg_a[s];
        const int i = m_seg_b[s];
        if (m_inv_mass[i] == 0.0f)
            continue;
        const Vector3 seg_vec = m_points[i] - m_points[prev];
        const double seg_len = seg_vec.length();
        if (seg_len < 0.0001)
        {
            m_stuck_passes[i] = 0;
            continue;
        }
        m_ray_query->set_from(m_points[prev]);
        m_ray_query->set_to(m_points[i] + seg_vec * (m_collision_radius / seg_len));
        Dictionary entry = space_state->intersect_ray(m_ray_query);
        const Vector3 entry_n = entry.is_empty() ? Vector3() : entry["normal"].operator Vector3();
        // Must be meaningfully behind the entered face (not a corner graze)…
        if (entry_n == Vector3() ||
            (m_points[i] - entry["position"].operator Vector3()).dot(entry_n) > -m_collision_radius)
        {
            m_stuck_passes[i] = 0;
            continue;
        }
        // …and the reverse ray must exit through an opposing face.
        m_ray_query->set_from(m_points[i]);
        m_ray_query->set_to(m_points[prev]);
        Dictionary exit = space_state->intersect_ray(m_ray_query);
        if (exit.is_empty() || entry_n.dot(exit["normal"].operator Vector3()) > -0.7)
        {
            m_stuck_passes[i] = 0;
            continue;
        }
        m_stuck_passes[i] += 1;
        if (m_stuck_passes[i] < 2)
            continue;
        m_stuck_passes[i] = 0;
        m_points[i] = entry["position"].operator Vector3() + entry_n * m_collision_radius;
        m_prev_points[i] = m_points[i];
        m_c_flags[i] = 0;
        m_mid_contact[s] = 0;
        if (m_next_seg[i] >= 0)
            m_mid_contact[m_next_seg[i]] = 0;
    }
}

// Free any particle the last lay buried inside a solid. A cord is laid as a
// straight line between its anchors, and a restore or teleport can put
// furniture on that line. A buried particle is invisible to every contact
// pass — the motion sweep only sees crossings and the rest query refuses
// planes the particle is behind — so it stayed wedged for ever (measured 11 mm
// inside a table). Runs once per lay, on the first tick after it: each buried
// particle is walked out through its nearest face, ray-probed from OUTSIDE
// because a ray cast from inside a solid reports nothing. Point containment
// only answers for convex shapes, which is what furniture is made of; a lay
// through a concave trimesh stays a known gap.
void VerletRope::DepenetrateLay()
{
    if (m_surface_collision_mask == 0 || m_point_query.is_null() ||
        m_ray_query.is_null() || m_shape_query.is_null())
        return;
    Ref<World3D> world = get_world_3d();
    if (world.is_null())
        return;
    PhysicsDirectSpaceState3D *space_state = world->get_direct_space_state();
    if (space_state == nullptr)
        return;

    // A restore can place the whole direct anchor-to-anchor lay through a
    // tabletop. Ejecting each buried particle independently is not sufficient:
    // neighbours choose opposite faces, leaving a segment threaded through the
    // slab and the stretch/contact solvers fight forever. Before the pointwise
    // fallback below, route a buried trunk coherently through a small temporary
    // occupancy grid around its anchors. This is intentionally a one-shot lay
    // repair, not a per-frame pathfinder.
    const auto repair_chain = [&](int first, int point_count, double rest_length) -> bool {
        if (point_count < 2)
            return false;
        bool buried = false;
        for (int k = 1; k < point_count - 1; ++k)
        {
            m_point_query->set_position(m_points[first + k]);
            if (!space_state->intersect_point(m_point_query, 1).is_empty())
            {
                buried = true;
                break;
            }
        }
        // A thin slab can sit wholly between adjacent particle centres, so no
        // point is contained even though the rendered cable passes through it.
        // Opposing hits from the two directions distinguish a true entry/exit
        // crossing from a legitimate graze over a convex edge.
        if (!buried)
        {
            for (int k = 0; k < point_count - 1; ++k)
            {
                const Vector3 a = m_points[first + k];
                const Vector3 b = m_points[first + k + 1];
                m_ray_query->set_from(a);
                m_ray_query->set_to(b);
                const Dictionary entry = space_state->intersect_ray(m_ray_query);
                if (entry.is_empty())
                    continue;
                m_ray_query->set_from(b);
                m_ray_query->set_to(a);
                const Dictionary exit = space_state->intersect_ray(m_ray_query);
                if (exit.is_empty())
                    continue;
                const Vector3 entry_n = entry["normal"];
                const Vector3 exit_n = exit["normal"];
                if (entry_n != Vector3() && exit_n != Vector3() && entry_n.dot(exit_n) < -0.7)
                {
                    buried = true;
                    break;
                }
            }
        }
        if (!buried)
            return false;

        const Vector3 start = m_points[first];
        const Vector3 goal = m_points[first + point_count - 1];
        const double direct = start.distance_to(goal);
        const double slack = std::fmax(0.0, rest_length - direct);
        // The obstacle's nearest edge can be much farther away than the raw
        // cable slack (a controller near the middle of a wide tabletop is the
        // common case), so the search needs a real furniture-sized halo.
        double margin = CLAMP(slack * 0.6 + 0.40, 0.45, 0.90);
        double cell = CLAMP(rest_length / static_cast<double>(point_count - 1) * 2.0,
                            0.055, 0.10);
        Vector3 lo(std::fmin(start.x, goal.x) - margin,
                   std::fmin(start.y, goal.y) - margin,
                   std::fmin(start.z, goal.z) - margin);
        Vector3 hi(std::fmax(start.x, goal.x) + margin,
                   std::fmax(start.y, goal.y) + margin,
                   std::fmax(start.z, goal.z) + margin);

        auto dims_for = [&](double c) {
            return Vector3i(static_cast<int>(std::ceil((hi.x - lo.x) / c)) + 1,
                            static_cast<int>(std::ceil((hi.y - lo.y) / c)) + 1,
                            static_cast<int>(std::ceil((hi.z - lo.z) / c)) + 1);
        };
        Vector3i dims = dims_for(cell);
        constexpr int MAX_NODES = 120000;
        while (static_cast<int64_t>(dims.x) * dims.y * dims.z > MAX_NODES && cell < 0.16)
        {
            cell *= 1.2;
            dims = dims_for(cell);
        }
        const int64_t node_count_64 = static_cast<int64_t>(dims.x) * dims.y * dims.z;
        if (dims.x < 2 || dims.y < 2 || dims.z < 2 || node_count_64 > MAX_NODES)
            return false;
        const int node_count = static_cast<int>(node_count_64);

        const auto clamp_coord = [&](const Vector3 &p) {
            return Vector3i(CLAMP(static_cast<int>(std::lround((p.x - lo.x) / cell)), 0, dims.x - 1),
                            CLAMP(static_cast<int>(std::lround((p.y - lo.y) / cell)), 0, dims.y - 1),
                            CLAMP(static_cast<int>(std::lround((p.z - lo.z) / cell)), 0, dims.z - 1));
        };
        const auto index_of = [&](const Vector3i &c) {
            return (c.z * dims.y + c.y) * dims.x + c.x;
        };
        const auto coord_of = [&](int index) {
            const int x = index % dims.x;
            index /= dims.x;
            const int y = index % dims.y;
            const int z = index / dims.y;
            return Vector3i(x, y, z);
        };
        const Vector3i start_c = clamp_coord(start);
        const Vector3i goal_c = clamp_coord(goal);
        const int start_i = index_of(start_c);
        const int goal_i = index_of(goal_c);
        const auto position_of = [&](int index) {
            if (index == start_i)
                return start;
            if (index == goal_i)
                return goal;
            const Vector3i c = coord_of(index);
            return lo + Vector3(c.x * cell, c.y * cell, c.z * cell);
        };

        std::vector<int8_t> occupied(node_count, -1);
        const auto is_occupied = [&](int index) {
            if (index == start_i || index == goal_i)
                return false;
            if (occupied[index] >= 0)
                return occupied[index] != 0;
            m_shape_query->set_motion(Vector3());
            m_shape_query->set_transform(Transform3D(Basis(), position_of(index)));
            const bool hit = !space_state->intersect_shape(m_shape_query, 1).is_empty();
            occupied[index] = hit ? 1 : 0;
            return hit;
        };

        const double inf = std::numeric_limits<double>::infinity();
        std::vector<double> cost(node_count, inf);
        std::vector<int> parent(node_count, -1);
        using OpenNode = std::pair<double, int>;
        std::priority_queue<OpenNode, std::vector<OpenNode>, std::greater<OpenNode>> open;
        cost[start_i] = 0.0;
        open.push({start.distance_to(goal), start_i});
        int expanded = 0;
        while (!open.empty() && expanded++ < MAX_NODES)
        {
            const int current = open.top().second;
            open.pop();
            if (current == goal_i)
                break;
            const Vector3i cc = coord_of(current);
            for (int dz = -1; dz <= 1; ++dz)
            for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx)
            {
                if (dx == 0 && dy == 0 && dz == 0)
                    continue;
                const Vector3i step(dx, dy, dz);
                const Vector3i nc = cc + step;
                if (nc.x < 0 || nc.y < 0 || nc.z < 0 ||
                    nc.x >= dims.x || nc.y >= dims.y || nc.z >= dims.z)
                    continue;
                const int next = index_of(nc);
                if (is_occupied(next))
                    continue;
                const Vector3 current_pos = position_of(current);
                const Vector3 next_pos = position_of(next);
                // An attachment point may legitimately begin just inside the
                // supporting tabletop even though its host body is excluded.
                // A shape cast starting overlapped reports zero safe motion in
                // every direction and strands the A* start. Let the first/last
                // edge escape; the neighbouring cell itself must still be free.
                if (current != start_i && next != goal_i)
                {
                    m_shape_query->set_transform(Transform3D(Basis(), current_pos));
                    m_shape_query->set_motion(next_pos - current_pos);
                    const PackedFloat32Array sweep = space_state->cast_motion(m_shape_query);
                    if (sweep.size() >= 1 && sweep[0] < 0.999f)
                        continue;
                }
                const double next_cost = cost[current] + current_pos.distance_to(next_pos);
                if (next_cost >= cost[next])
                    continue;
                cost[next] = next_cost;
                parent[next] = current;
                open.push({next_cost + position_of(next).distance_to(goal), next});
            }
        }
        m_shape_query->set_motion(Vector3());
        if (start_i != goal_i && parent[goal_i] < 0)
            return false;

        std::vector<Vector3> path;
        for (int at = goal_i; at >= 0; at = parent[at])
        {
            path.push_back(position_of(at));
            if (at == start_i)
                break;
        }
        if (path.size() < 2 || path.back().distance_squared_to(start) > 1e-8)
            return false;
        std::reverse(path.begin(), path.end());

        std::vector<double> cumulative(path.size(), 0.0);
        for (size_t i = 1; i < path.size(); ++i)
            cumulative[i] = cumulative[i - 1] + path[i - 1].distance_to(path[i]);
        const double path_length = cumulative.back();
        // A restored placement can be slightly beyond the cable's true reach.
        // Keep a coherent route up to a bounded 1.5x strain; the ordinary
        // tension/coupling path can then move a free endpoint. Rejecting it here
        // falls back to the much worse state of a short segment threaded through
        // the obstacle.
        if (path_length < 1e-6 || path_length > rest_length * 1.5)
            return false;
        for (int k = 0; k < point_count; ++k)
        {
            const double target = path_length * static_cast<double>(k) /
                                  static_cast<double>(point_count - 1);
            size_t edge = 1;
            while (edge < cumulative.size() && cumulative[edge] < target)
                ++edge;
            if (edge >= cumulative.size())
                edge = cumulative.size() - 1;
            const double span = cumulative[edge] - cumulative[edge - 1];
            const double t = span > 1e-9 ? (target - cumulative[edge - 1]) / span : 0.0;
            m_points[first + k] = path[edge - 1].lerp(path[edge], t);
            m_prev_points[first + k] = m_points[first + k];
        }
        return true;
    };

    const bool trunk_repaired = repair_chain(0, TrunkCount(), RestLength());
    if (trunk_repaired)
    {
        std::fill(m_c_flags.begin(), m_c_flags.end(), 0);
        std::fill(m_mid_contact.begin(), m_mid_contact.end(), 0);
        std::fill(m_stuck_passes.begin(), m_stuck_passes.end(), 0);
    }
    // Deeper than half a PROBE inside anything and the lay was hopeless anyway.
    constexpr double PROBE = 0.6;
    static const Vector3 DIRS[6] = {Vector3(1, 0, 0),  Vector3(-1, 0, 0), Vector3(0, 1, 0),
                                    Vector3(0, -1, 0), Vector3(0, 0, 1),  Vector3(0, 0, -1)};
    const int count = static_cast<int>(m_points.size());
    for (int i = 0; i < count; ++i)
    {
        if (m_inv_mass[i] == 0.0f)
            continue;
        m_point_query->set_position(m_points[i]);
        if (space_state->intersect_point(m_point_query, 1).is_empty())
            continue;
        double best = PROBE;
        Vector3 best_pos;
        Vector3 best_n;
        for (const Vector3 &d : DIRS)
        {
            m_ray_query->set_from(m_points[i] + d * PROBE);
            m_ray_query->set_to(m_points[i]);
            Dictionary hit = space_state->intersect_ray(m_ray_query);
            if (hit.is_empty())
                continue;
            const Vector3 hp = hit["position"];
            const double dist = hp.distance_to(m_points[i]);
            if (dist < best)
            {
                best = dist;
                best_pos = hp;
                best_n = hit["normal"];
            }
        }
        if (best >= PROBE || best_n == Vector3())
            continue;
        m_points[i] = best_pos + best_n * m_collision_radius;
        m_prev_points[i] = m_points[i];
    }
}

// Pull back on an anchor's rigidbody when the cable it holds is stretched past
// its rest length. This is the ONLY path by which the rope moves a plug: a
// pinned particle has inverse mass 0, so the plug drives the rope and never the
// other way about.
void VerletRope::ApplyAnchorCoupling()
{
    if (m_anchor_pull <= 0.0)
        return;

    // Trunk, between its own two anchors. Needs both: with a fray there is no
    // trunk anchor at all and the branches below do the work instead.
    if (m_start_cached && m_end_cached)
    {
        const Vector3 ps = AnchorPoint(m_start_cached, m_start_anchor_offset, Vector3());
        const Vector3 pe = AnchorPoint(m_end_cached, m_end_anchor_offset, Vector3());
        const double excess = ps.distance_to(pe) - RestLength();
        if (excess > 0.0)
        {
            const double force = excess * m_anchor_pull;
            if (m_start_body)
                m_start_body->apply_force((pe - ps).normalized() * force,
                                          ps - m_start_body->get_global_position());
            if (m_end_body)
                m_end_body->apply_force((ps - pe).normalized() * force,
                                        pe - m_end_body->get_global_position());
        }
    }

    // Each branch, between its plug and the breakout it hangs off. Without this
    // a lead frayed at both ends has no coupling whatsoever — pick up one plug of
    // a composite lead, walk away, and the other five sit exactly where they are
    // while the cable stretches without limit.
    for (const FrayChain &fc : m_fray)
    {
        if (fc.body == nullptr)
            continue;
        const Vector3 plug = AnchorPoint(fc.cached, fc.offset, Vector3());
        const Vector3 junction = m_points[fc.head];
        const double excess = plug.distance_to(junction) - fc.count * FraySegLength();
        if (excess <= 0.0)
            continue;
        fc.body->apply_force((junction - plug).normalized() * (excess * m_anchor_pull),
                             plug - fc.body->get_global_position());
    }
}

void VerletRope::UpdateSleepState()
{
    const int count = static_cast<int>(m_points.size());
    double max_velocity_sq = 0.0;
    double velocity_sum_sq = 0.0;
    // Measure final-pose motion from the previous physics tick, not Verlet's
    // internal current-minus-history velocity. Constraints intentionally edit
    // the latter: a directional strain-relief boot corrects its first particle
    // after stretch on every iteration and can therefore report perpetual
    // energy even after the visible centreline has reached a fixed point. The
    // render snapshot is rolled only after this function, so m_curr_render is
    // exactly the preceding tick's solved particle layout.
    const bool have_previous_pose = static_cast<int>(m_curr_render.size()) == count;
    for (int i = 0; i < count; ++i)
    {
        const double velocity_sq = have_previous_pose
                                       ? m_points[i].distance_squared_to(m_curr_render[i])
                                       : m_points[i].distance_squared_to(m_prev_points[i]);
        max_velocity_sq = std::max(max_velocity_sq, velocity_sq);
        velocity_sum_sq += velocity_sq;
    }
    // Gate both the peak and the rope's actual pose energy so localized solver
    // dust can sleep but visible whole-cable squirm cannot.
    const bool velocity_still = max_velocity_sq <= SLEEP_MAX_VELOCITY_EPS_SQ &&
                                velocity_sum_sq / std::max(1, count) <=
                                    SLEEP_RMS_VELOCITY_EPS_SQ;
    m_debug_max_velocity = std::sqrt(max_velocity_sq);
    m_debug_rms_velocity = std::sqrt(velocity_sum_sq / std::max(1, count));

    double worst_stretch_error = 0.0;
    int worst_stretch_segment = -1;
    for (int s = 0; s < static_cast<int>(m_seg_a.size()); ++s)
    {
        const double rest = m_seg_rest[s];
        if (rest > 1e-8)
        {
            const double error =
                std::abs(m_points[m_seg_a[s]].distance_to(m_points[m_seg_b[s]]) - rest) / rest;
            if (error > worst_stretch_error)
            {
                worst_stretch_error = error;
                worst_stretch_segment = s;
            }
        }
    }

    double worst_contact_error = 0.0;
    for (int i = 0; i < count; ++i)
    {
        if (m_c_flags[i] & 1)
        {
            worst_contact_error = std::max(
                worst_contact_error,
                std::max(0.0, m_collision_radius - (m_points[i] - m_c_p1[i]).dot(m_c_n1[i])));
        }
        if (m_c_flags[i] & 2)
        {
            worst_contact_error = std::max(
                worst_contact_error,
                std::max(0.0, m_collision_radius - (m_points[i] - m_c_p2[i]).dot(m_c_n2[i])));
        }
    }
    for (int s = 0; s < static_cast<int>(m_mid_contact.size()); ++s)
    {
        if (m_mid_contact[s] == 0)
            continue;
        if (m_mid_contact[s] & 1)
        {
            const Vector3 p = m_points[m_seg_a[s]].lerp(m_points[m_seg_b[s]],
                                                        m_mid_contact_t[s]);
            worst_contact_error = std::max(
                worst_contact_error,
                std::max(0.0, m_collision_radius -
                                  (p - m_mid_contact_point[s]).dot(m_mid_contact_normal[s])));
        }
        if (m_mid_contact[s] & 2)
        {
            const Vector3 p = m_points[m_seg_a[s]].lerp(m_points[m_seg_b[s]],
                                                        m_mid_contact_t_2[s]);
            worst_contact_error = std::max(
                worst_contact_error,
                std::max(0.0, m_collision_radius -
                                  (p - m_mid_contact_point_2[s]).dot(m_mid_contact_normal_2[s])));
        }
    }
    if (worst_contact_error <= SLEEP_CONTACT_ERROR)
        m_contact_stable_frames += 1;
    else
        m_contact_stable_frames = 0;

    const Vector3 a_start = AnchorPoint(m_start_cached, m_start_anchor_offset, m_sleep_anchor_start);
    const Vector3 a_end = AnchorPoint(m_end_cached, m_end_anchor_offset, m_sleep_anchor_end);
    bool anchors_still = true;
    // Hosts, sockets and hands are external authority and must be stationary.
    // A free plug belongs to the rope system itself; Jolt can roll its small
    // sphere by microscopic amounts forever, and SleepNow is specifically what
    // latches that body once the cable's kinetic criteria are met.
    const EndpointRole sleep_start_role = ResolveEndpointRole(m_start_cached, m_start_endpoint_role);
    const EndpointRole sleep_end_role = ResolveEndpointRole(m_end_cached, m_end_endpoint_role);
    const auto quiet_host = [](RigidBody3D *body, EndpointRole role) {
        return role == ENDPOINT_HOST && body != nullptr &&
               body->get_linear_velocity().length_squared() < 0.3 * 0.3 &&
               body->get_angular_velocity().length_squared() < 3.0 * 3.0;
    };
    if (!EndpointIsFree(sleep_start_role) && !quiet_host(m_start_body, sleep_start_role) &&
        a_start.distance_squared_to(m_sleep_anchor_start) > WAKE_ANCHOR_EPS_SQ)
        anchors_still = false;
    if (!EndpointIsFree(sleep_end_role) && !quiet_host(m_end_body, sleep_end_role) &&
        a_end.distance_squared_to(m_sleep_anchor_end) > WAKE_ANCHOR_EPS_SQ)
        anchors_still = false;
    m_sleep_anchor_start = a_start;
    m_sleep_anchor_end = a_end;
    for (FrayChain &fc : m_fray)
    {
        const Vector3 a = AnchorPoint(fc.cached, fc.offset, fc.sleep_pos);
        if (!EndpointIsFree(ResolveEndpointRole(fc.cached, ENDPOINT_AUTO)) &&
            a.distance_squared_to(fc.sleep_pos) > WAKE_ANCHOR_EPS_SQ)
            anchors_still = false;
        fc.sleep_pos = a;
    }
    if (!anchors_still)
        m_contact_stable_frames = 0;
    const bool constraints_settled = worst_stretch_error <= SLEEP_STRETCH_ERROR &&
                                     worst_contact_error <= SLEEP_CONTACT_ERROR;
    m_debug_stretch_error = worst_stretch_error;
    m_debug_contact_error = worst_contact_error;
    // A controller or sensor bar is the physical host at a plain Node3D anchor.
    // Jolt may keep a resting host microscopically rocking on an edge; because
    // the endpoint is pinned, that motion drives the whole cable forever. Once
    // the rope manifold is established and the host itself is already moving
    // below ordinary grab/throw speeds, let the physics body sleep. Any grab,
    // force or transform change wakes the body and AnchorsMoved wakes the rope.
    const auto latch_resting_host = [this](RigidBody3D *body, EndpointRole role) {
        if (body == nullptr || role != ENDPOINT_HOST || body->is_sleeping())
            return;
        if (body->has_method("is_picked_up") && static_cast<bool>(body->call("is_picked_up")))
            return;
        if (body->get_linear_velocity().length_squared() < 0.3 * 0.3 &&
            body->get_angular_velocity().length_squared() < 3.0 * 3.0)
            body->set_sleeping(true);
    };
    if (m_contact_stable_frames > 90 && constraints_settled)
    {
        latch_resting_host(m_start_body, sleep_start_role);
        latch_resting_host(m_end_body, sleep_end_role);
    }
    // A restored legacy lay can be legal at every particle yet have one segment
    // trapped between stale planes on opposite sides of furniture. Contact then
    // wins the last write of every iteration and leaves that segment >2x long,
    // injecting a large correction forever. Drop only the local manifold once;
    // the swept/rest queries rebuild it from the live geometry next tick.
    if (!m_settle_repair_attempted && m_contact_stable_frames > 180 &&
        m_debug_max_velocity > 0.005 && worst_stretch_error > 0.5 &&
        worst_stretch_segment >= 0)
    {
        const int a = m_seg_a[worst_stretch_segment];
        const int b = m_seg_b[worst_stretch_segment];
        m_c_flags[a] = 0;
        m_c_flags[b] = 0;
        m_mid_contact[worst_stretch_segment] = 0;
        if (m_next_seg[a] >= 0)
            m_mid_contact[m_next_seg[a]] = 0;
        if (m_next_seg[b] >= 0)
            m_mid_contact[m_next_seg[b]] = 0;
        m_prev_points = m_points;
        m_contact_stable_frames = 0;
        m_settle_repair_attempted = true;
    }
    // A contact-driven limit cycle can continuously replace the tiny amount of
    // global Verlet damping (edge impact -> stretch correction -> edge impact).
    // Once the manifold and anchors have stayed valid for a full second, add
    // physical contact damping to the history. The ordinary velocity gate still
    // decides sleep; this merely lets energy leave instead of freezing motion.
    if (!velocity_still && anchors_still && constraints_settled &&
        m_contact_stable_frames > 90)
    {
        constexpr double CONTACT_SETTLE_RETAIN = 0.5;
        for (int i = 0; i < count; ++i)
            if (m_inv_mass[i] != 0.0f)
                m_prev_points[i] = m_points[i] -
                                   (m_points[i] - m_prev_points[i]) * CONTACT_SETTLE_RETAIN;
    }
    if (velocity_still && anchors_still && constraints_settled &&
        m_contact_stable_frames >= m_raycast_interval * 2)
    {
        m_still_frames += 1;
        if (m_still_frames >= SLEEP_FRAMES)
        {
            SleepNow();
        }
    }
    else
        m_still_frames = std::max(0, m_still_frames - 1);
}

} // namespace Xenu
