// VerletRope — tube meshing and render-time interpolation. Split from
// VerletRope.cpp to keep the files readable.
//
// The tube cannot use ARRAY_NORMAL: positions are re-uploaded every frame
// through surface_update_vertex_region, and normals share that same vertex
// buffer, so adding them means rebuilding the whole surface each frame — a GPU
// buffer reallocation per rope per frame, which is exactly what this avoids.
// Custom attributes live in the ATTRIBUTE buffer instead, which has its own
// region-update call, so the normal rides along for one extra bulk upload.
//
// A ribbon cable whose cords differ in colour draws one SURFACE per cord, each
// with its own material, rather than one surface carrying per-vertex colour:
// colour would have to live in the attribute buffer next to CUSTOM0, and the
// per-frame region upload rewrites that whole buffer. Cords that all wear ONE
// colour - the composite lead, black on every cord - share a single surface
// instead, each cord at its own offset in the buffers: the mobile renderer
// issues a draw per surface, and three of the same material were three draws
// where one does. Every cord shares the trunk's simulated centreline and is
// offset laterally in its transport frame, so the extra cost is meshing, never
// solving.

#include "VerletRope.hpp"

#include <godot_cpp/classes/engine.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace Xenu
{

namespace
{
constexpr double RENDER_FOLLOW_EPS_SQ = 0.0001 * 0.0001;

// Ease a cord from its trunk slot into its in-group slot. Smoothstep rather than
// a straight lerp so the tube leaves the junction tangent to the ribbon instead
// of kinking away from it.
inline float FrayEase(int p_from_junction, int p_taper)
{
    if (p_taper <= 0)
        return 1.0f;
    const float t = std::min(1.0f, static_cast<float>(p_from_junction) / static_cast<float>(p_taper));
    return t * t * (3.0f - 2.0f * t);
}
} // namespace

void VerletRope::BuildTrigTables()
{
    m_cos_table.resize(m_tube_sides);
    m_sin_table.resize(m_tube_sides);
    for (int j = 0; j < m_tube_sides; ++j)
    {
        const double angle = Math_TAU * static_cast<double>(j) / static_cast<double>(m_tube_sides);
        m_cos_table[j] = static_cast<float>(std::cos(angle));
        m_sin_table[j] = static_cast<float>(std::sin(angle));
    }
}

// Points on one cord's drawn centreline: its start branch, the trunk, its end
// branch. Every cord has the same count, so every surface does too.
int VerletRope::CordPointCount() const
{
    int n = TrunkCount();
    if (m_fray_segments_start > 0)
        n += m_fray_segments_start;
    if (m_fray_segments_end > 0)
        n += m_fray_segments_end;
    return n;
}

void VerletRope::BuildMeshTopology()
{
    if (static_cast<int>(m_cos_table.size()) != m_tube_sides)
        BuildTrigTables();
    RebuildMaterials();

    const int cords = m_ribbon_count > 0 ? m_ribbon_count : 1;
    const int ring_count = (CordPointCount() - 1) * Subdiv() + 1;
    const int seg_rings = ring_count - 1;

    m_ring_points.assign(ring_count, Vector3());
    m_ring_side.assign(ring_count, Vector3());
    m_ring_up.assign(ring_count, Vector3());
    m_ring_lat.assign(ring_count, 0.0f);

    const int vertex_count = ring_count * m_tube_sides;
    PackedVector3Array vertex_array;
    vertex_array.resize(vertex_count);
    PackedFloat32Array normal_array;
    normal_array.resize(vertex_count * 4);

    // Index buffer — topology never changes, built once and shared by every
    // cord's surface, which all have identical geometry.
    PackedInt32Array index_array;
    index_array.resize(seg_rings * m_tube_sides * 6);
    {
        int32_t *idx_w = index_array.ptrw();
        int idx = 0;
        for (int i = 0; i < seg_rings; ++i)
        {
            for (int j = 0; j < m_tube_sides; ++j)
            {
                const int a = i * m_tube_sides + j;
                const int b = i * m_tube_sides + (j + 1) % m_tube_sides;
                const int c = (i + 1) * m_tube_sides + j;
                const int d = (i + 1) * m_tube_sides + (j + 1) % m_tube_sides;
                idx_w[idx] = a;
                idx_w[idx + 1] = b;
                idx_w[idx + 2] = c;
                idx_w[idx + 3] = b;
                idx_w[idx + 4] = d;
                idx_w[idx + 5] = c;
                idx += 6;
            }
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertex_array;
    arrays[Mesh::ARRAY_INDEX] = index_array;
    // PackedFloat32Array, NOT bytes: the *_FLOAT custom formats are validated as
    // PACKED_FLOAT32_ARRAY here and the surface silently fails to build
    // otherwise. (The region updates below do want bytes.)
    arrays[Mesh::ARRAY_CUSTOM0] = normal_array;

    Ref<ArrayMesh> am;
    am.instantiate();
    const uint64_t fmt = static_cast<uint64_t>(Mesh::ARRAY_CUSTOM_RGBA_FLOAT)
                         << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT;
    const bool merged = cords > 1 && CordsShareColour();
    if (merged)
    {
        // Every cord's vertices in one buffer, cord c starting at
        // c * vertex_count; the index array is the same topology repeated with
        // that offset. RenderCord uploads each cord's region into the one
        // surface.
        PackedVector3Array all_vertices;
        all_vertices.resize(vertex_count * cords);
        PackedFloat32Array all_normals;
        all_normals.resize(vertex_count * 4 * cords);
        PackedInt32Array all_indices;
        const int per_cord = static_cast<int>(index_array.size());
        all_indices.resize(per_cord * cords);
        int32_t *iw = all_indices.ptrw();
        const int32_t *ir = index_array.ptr();
        for (int c = 0; c < cords; ++c)
            for (int k = 0; k < per_cord; ++k)
                iw[c * per_cord + k] = ir[k] + c * vertex_count;
        arrays[Mesh::ARRAY_VERTEX] = all_vertices;
        arrays[Mesh::ARRAY_INDEX] = all_indices;
        arrays[Mesh::ARRAY_CUSTOM0] = all_normals;
        am->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                                    Dictionary(), fmt);
        am->surface_set_material(0, m_materials[0]);
    }
    else
    {
        for (int c = 0; c < cords; ++c)
        {
            am->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                                        Dictionary(), fmt);
            am->surface_set_material(c, m_materials[c]);
        }
    }
    set_mesh(am);
    m_built_merged = merged;
    m_built_vertices = vertex_count;

    // Staging buffers for the per-frame region uploads, sized once. One pair per
    // cord: the region update queues the array for the render thread, so writing
    // through ptrw() on a buffer another surface still holds would fork it.
    m_vertex_bytes.assign(cords, PackedByteArray());
    m_normal_bytes.assign(cords, PackedByteArray());
    for (int c = 0; c < cords; ++c)
    {
        m_vertex_bytes[c].resize(vertex_count * static_cast<int>(sizeof(float)) * 3);
        m_normal_bytes[c].resize(vertex_count * static_cast<int>(sizeof(float)) * 4);
    }

    m_built_cords = cords;
    m_built_rings = ring_count;
    m_built_sides = m_tube_sides;
    m_mesh_dirty = true;
}

// Gather cord c's centreline out of the render points, plus the lateral slot it
// occupies at each one. The branches are walked outward from the junction so the
// ease reads the same at both ends; the start branch is emitted in reverse
// because the drawn cord runs plug -> junction -> trunk -> junction -> plug.
void VerletRope::BuildCordPath(int p_cord)
{
    const int trunk_n = TrunkCount();
    const float lat_trunk = m_lat_trunk.empty() ? 0.0f : m_lat_trunk[p_cord];
    m_cord_points.clear();
    m_cord_lat.clear();

    const int sc = m_cord_start_chain.empty() ? -1 : m_cord_start_chain[p_cord];
    if (sc >= 0)
    {
        const FrayChain &fc = m_fray[sc];
        const float lat_group = m_lat_start[p_cord];
        for (int k = fc.count - 1; k >= 0; --k)
        {
            m_cord_points.push_back(m_render_points[fc.first + k]);
            const float e = FrayEase(k + 1, m_fray_taper_segments);
            m_cord_lat.push_back(lat_trunk + (lat_group - lat_trunk) * e);
        }
    }

    for (int i = 0; i < trunk_n; ++i)
    {
        m_cord_points.push_back(m_render_points[i]);
        m_cord_lat.push_back(lat_trunk);
    }

    const int ec = m_cord_end_chain.empty() ? -1 : m_cord_end_chain[p_cord];
    if (ec >= 0)
    {
        const FrayChain &fc = m_fray[ec];
        const float lat_group = m_lat_end[p_cord];
        for (int k = 0; k < fc.count; ++k)
        {
            m_cord_points.push_back(m_render_points[fc.first + k]);
            const float e = FrayEase(k + 1, m_fray_taper_segments);
            m_cord_lat.push_back(lat_trunk + (lat_group - lat_trunk) * e);
        }
    }
}

// Fill m_ring_points (and m_ring_lat for a ribbon) from a cord path — straight
// copy, or Catmull-Rom subdivision when smoothing > 0. The lateral track
// subdivides linearly: it is already a smooth ease, and splining it would
// overshoot the in-group slot.
void VerletRope::FillRingPoints(const std::vector<Vector3> &p_src, bool p_with_lat)
{
    const int count = static_cast<int>(p_src.size());
    const int sub = Subdiv();
    if (sub == 1)
    {
        for (int i = 0; i < count; ++i)
            m_ring_points[i] = p_src[i];
        if (p_with_lat)
            for (int i = 0; i < count; ++i)
                m_ring_lat[i] = m_cord_lat[i];
        return;
    }
    int r = 0;
    for (int i = 0; i < count - 1; ++i)
    {
        const Vector3 p0 = p_src[i - 1 > 0 ? i - 1 : 0];
        const Vector3 p1 = p_src[i];
        const Vector3 p2 = p_src[i + 1];
        const Vector3 p3 = p_src[i + 2 < count - 1 ? i + 2 : count - 1];
        const float l1 = p_with_lat ? m_cord_lat[i] : 0.0f;
        const float l2 = p_with_lat ? m_cord_lat[i + 1] : 0.0f;
        for (int s = 0; s < sub; ++s)
        {
            const double t = static_cast<double>(s) / static_cast<double>(sub);
            const double t2 = t * t;
            const double t3 = t2 * t;
            m_ring_points[r] = 0.5 * ((2.0 * p1) + (-p0 + p2) * t +
                                      (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
                                      (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
            if (p_with_lat)
                m_ring_lat[r] = l1 + (l2 - l1) * static_cast<float>(t);
            r += 1;
        }
    }
    m_ring_points[r] = p_src[count - 1];
    if (p_with_lat)
        m_ring_lat[r] = m_cord_lat[count - 1];
}

void VerletRope::RenderCord(int p_cord)
{
    // A plain round cord's path IS the render points, so it skips the gather and
    // meshes at exactly the cost it did before ribbons existed. m_ring_lat stays
    // the zeroes BuildMeshTopology left, so the offset below falls out.
    const bool plain = IsPlainCord();
    if (plain)
    {
        FillRingPoints(m_render_points, false);
    }
    else
    {
        BuildCordPath(p_cord);
        FillRingPoints(m_cord_points, true);
    }
    const int count = static_cast<int>(m_ring_points.size());
    const double pitch = CordPitch();

    // Parallel-transport (rotation-minimizing) frames: build the first ring's
    // basis from any perpendicular, then carry it along the tube by projecting
    // the previous side vector onto each new tangent plane. Computing frames
    // independently from a fixed reference vector twists neighbouring rings
    // against each other whenever the tangent nears that reference, which
    // pinches the tube like sausage links.
    //
    // The seed is not arbitrary for a ribbon: `side` is the direction the cords
    // are laid out along, so it decides which way the flat "ooo" faces. Take it
    // from the start anchor's basis, which is the connector the ribbon leaves.
    // With a single round cord the roll was invisible and this changes nothing.
    //
    // Resolved through the ObjectID rather than read off m_start_cached, which
    // is not safe here: that cache is refreshed by ReconcileAnchors(), which
    // only runs from Step() on the PHYSICS tick, while this is the RENDER tick.
    // Free the start node and the two ticks disagree — worse at teardown, where
    // physics has already stopped and _process still gets one more frame, so the
    // cache is guaranteed stale. Step() also returns before reconciling when the
    // rope has no points, so an empty rope never refreshes it at all. Both left
    // this line dereferencing freed memory (signal 11 in RenderCord, rdx
    // 0xBAADF00D), which is what took motion_tests and time_of_day_tests down.
    Vector3 prev_side;
    if (Node3D *start = GetStartNode(); start != nullptr)
        prev_side = start->get_global_transform().basis.orthonormalized().xform(m_ribbon_axis);
    Vector3 prev_tangent(0, 1, 0);
    for (int i = 0; i < count; ++i)
    {
        Vector3 tangent;
        if (i == 0)
            tangent = m_ring_points[1] - m_ring_points[0];
        else if (i == count - 1)
            tangent = m_ring_points[i] - m_ring_points[i - 1];
        else
            tangent = m_ring_points[i + 1] - m_ring_points[i - 1];
        // Degeneracy guard, deliberately far below the ring spacing. At 0.0001
        // it meant 10 mm and fired on both END rings every frame: their tangent
        // is one-sided, and Catmull-Rom compresses the first and last sub-step.
        // The ring then got built around UP, putting its plane ALONG the cable
        // instead of across it, and the tube ended in a flat sliver at every
        // plug. Falling back to the previous tangent also beats a fixed axis: a
        // real degeneracy is two coincident points, where carrying the frame
        // forward is what the parallel transport wants anyway.
        if (tangent.length_squared() < 1e-12)
            tangent = prev_tangent;
        else
            tangent = tangent.normalized();
        prev_tangent = tangent;

        Vector3 side = prev_side - tangent * prev_side.dot(tangent);
        if (side.length_squared() < 0.000001)
        {
            const Vector3 ref = std::abs(tangent.dot(Vector3(0, 1, 0))) < 0.99 ? Vector3(0, 1, 0)
                                                                               : Vector3(1, 0, 0);
            side = tangent.cross(ref);
        }
        side = side.normalized();
        prev_side = side;
        m_ring_side[i] = side;
        m_ring_up[i] = side.cross(tangent).normalized();
    }

    // Fill the staging buffers directly — these go straight to the GPU.
    float *vw = reinterpret_cast<float *>(m_vertex_bytes[p_cord].ptrw());
    float *nw = reinterpret_cast<float *>(m_normal_bytes[p_cord].ptrw());
    for (int i = 0; i < count; ++i)
    {
        const int base = i * m_tube_sides;
        const Vector3 side = m_ring_side[i];
        const Vector3 up = m_ring_up[i];
        // The lateral offset rides the transport frame, so the ribbon twists
        // with the cable instead of staying pinned to a world axis.
        const Vector3 centre =
            plain ? m_ring_points[i] : m_ring_points[i] + side * (m_ring_lat[i] * pitch);
        for (int j = 0; j < m_tube_sides; ++j)
        {
            const Vector3 radial = side * m_cos_table[j] + up * m_sin_table[j];
            const Vector3 v = centre + radial * m_tube_radius;
            const int v3 = (base + j) * 3;
            vw[v3] = v.x;
            vw[v3 + 1] = v.y;
            vw[v3 + 2] = v.z;
            const int n4 = (base + j) * 4;
            nw[n4] = radial.x;
            nw[n4 + 1] = radial.y;
            nw[n4 + 2] = radial.z;
            nw[n4 + 3] = 0.0f;
        }
    }

    Ref<ArrayMesh> am = get_mesh();
    if (am.is_null())
        return;
    if (m_built_merged)
    {
        // One surface for every cord: this cord's region sits after the ones
        // before it. Positions are float3 and CUSTOM0 is float4, and neither
        // buffer holds anything else (no normal array, see the file header).
        const int64_t v_off = static_cast<int64_t>(p_cord) * m_built_vertices * 3 * sizeof(float);
        const int64_t n_off = static_cast<int64_t>(p_cord) * m_built_vertices * 4 * sizeof(float);
        am->surface_update_vertex_region(0, v_off, m_vertex_bytes[p_cord]);
        am->surface_update_attribute_region(0, n_off, m_normal_bytes[p_cord]);
        return;
    }
    am->surface_update_vertex_region(p_cord, 0, m_vertex_bytes[p_cord]);
    am->surface_update_attribute_region(p_cord, 0, m_normal_bytes[p_cord]);
}

void VerletRope::RenderTube()
{
    const int cords = std::min(m_ribbon_count > 0 ? m_ribbon_count : 1, m_built_cords);
    for (int c = 0; c < cords; ++c)
        RenderCord(c);

    // Keep culling bounds in sync — surface_update_vertex_region does NOT
    // recompute the mesh AABB (it stays a zero-size box at the origin), and this
    // node is top_level at the world origin, so without this the rope gets
    // frustum-culled whenever the origin is off-screen. m_render_points covers
    // the branches as well as the trunk; the growth covers the ribbon's width.
    AABB aabb(m_render_points[0], Vector3());
    for (size_t i = 1; i < m_render_points.size(); ++i)
        aabb = aabb.expand(m_render_points[i]);
    const double half_width = CordPitch() * 0.5 * static_cast<double>(cords - 1);
    set_custom_aabb(aabb.grow(m_collision_radius * 2.0 + half_width + m_tube_radius));
}

// Roll the render history forward one physics tick. Called at the end of every
// simulated tick, after the anchors are pinned.
void VerletRope::SnapshotRenderState()
{
    const size_t n = m_points.size();
    if (m_curr_render.size() != n)
    {
        m_prev_render = m_points;
        m_curr_render = m_points;
        m_render_points = m_points;
        m_interpolating = false;
        return;
    }
    bool moved = false;
    for (size_t i = 0; i < n; ++i)
    {
        m_prev_render[i] = m_curr_render[i];
        m_curr_render[i] = m_points[i];
        m_render_points[i] = m_points[i];
        if (!moved && m_prev_render[i].distance_squared_to(m_curr_render[i]) > RENDER_FOLLOW_EPS_SQ)
            moved = true;
    }
    m_interpolating = moved;
}

void VerletRope::_process(double)
{
    Remesh();
}

void VerletRope::Remesh()
{
    if (m_points.size() < 2 || m_built_cords == 0)
        return;
    // The whole rope has to be interpolated, not just its ends. Overriding only
    // the two end points put them on render time while every interior point
    // stayed on physics time, and that discontinuity pulsed the final segment
    // every frame — which read as the cord jittering, and pinched the tube
    // whenever the last two rings closed up enough for the tangent to collapse.
    // This is the same fraction Godot uses to draw the plug, so the cord end and
    // the plug agree by construction.
    if (m_interpolating && m_render_points.size() == m_curr_render.size())
    {
        const double f = CLAMP(Engine::get_singleton()->get_physics_interpolation_fraction(), 0.0, 1.0);
        for (size_t i = 0; i < m_render_points.size(); ++i)
            m_render_points[i] = m_prev_render[i].lerp(m_curr_render[i], f);
        m_mesh_dirty = true;
    }
    if (m_mesh_dirty)
    {
        RenderTube();
        m_mesh_dirty = false;
    }
}

} // namespace Xenu
