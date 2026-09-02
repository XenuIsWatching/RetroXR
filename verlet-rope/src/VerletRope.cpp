#include "VerletRope.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

namespace Xenu
{

namespace
{
constexpr double WAKE_ANCHOR_EPS_SQ = 0.0005 * 0.0005;
// Tighter than the wake threshold: this only costs a tube rebuild, whereas
// waking costs a full solve, so it can afford to notice smaller motion.
constexpr double RENDER_FOLLOW_EPS_SQ = 0.0001 * 0.0001;

constexpr const char *CABLE_SHADER_PATH = "res://Shaders/cable.gdshader";
} // namespace

// ── Binding ─────────────────────────────────────────────────────────────────

#define XENU_BIND_PROP(name, getter, setter, variant_type)                     \
    ClassDB::bind_method(D_METHOD(setter, "value"), &VerletRope::Set##name);   \
    ClassDB::bind_method(D_METHOD(getter), &VerletRope::Get##name);            \
    ADD_PROPERTY(PropertyInfo(variant_type, #name), setter, getter);

void VerletRope::_bind_methods()
{
    BIND_ENUM_CONSTANT(ENDPOINT_AUTO);
    BIND_ENUM_CONSTANT(ENDPOINT_HOST);
    BIND_ENUM_CONSTANT(ENDPOINT_FREE_PLUG);
    BIND_ENUM_CONSTANT(ENDPOINT_HELD_PLUG);
    BIND_ENUM_CONSTANT(ENDPOINT_SOCKETED_PLUG);

    // Property names deliberately match the GDScript ones exactly — the two
    // cable scenes and every caller in Scripts/ already use them.
    ClassDB::bind_method(D_METHOD("set_segment_count", "value"), &VerletRope::SetSegmentCount);
    ClassDB::bind_method(D_METHOD("get_segment_count"), &VerletRope::GetSegmentCount);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "segment_count"), "set_segment_count", "get_segment_count");

    ClassDB::bind_method(D_METHOD("set_segment_length", "value"), &VerletRope::SetSegmentLength);
    ClassDB::bind_method(D_METHOD("get_segment_length"), &VerletRope::GetSegmentLength);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "segment_length"), "set_segment_length", "get_segment_length");

    ClassDB::bind_method(D_METHOD("set_gravity", "value"), &VerletRope::SetGravity);
    ClassDB::bind_method(D_METHOD("get_gravity"), &VerletRope::GetGravity);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"), "set_gravity", "get_gravity");

    ClassDB::bind_method(D_METHOD("set_damping", "value"), &VerletRope::SetDamping);
    ClassDB::bind_method(D_METHOD("get_damping"), &VerletRope::GetDamping);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_damping", "get_damping");

    ClassDB::bind_method(D_METHOD("set_constraint_iterations", "value"), &VerletRope::SetConstraintIterations);
    ClassDB::bind_method(D_METHOD("get_constraint_iterations"), &VerletRope::GetConstraintIterations);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "constraint_iterations"),
                 "set_constraint_iterations", "get_constraint_iterations");

    ADD_GROUP("Stiffness", "");
    ClassDB::bind_method(D_METHOD("set_stretch_stiffness", "value"), &VerletRope::SetStretchStiffness);
    ClassDB::bind_method(D_METHOD("get_stretch_stiffness"), &VerletRope::GetStretchStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stretch_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_stretch_stiffness", "get_stretch_stiffness");

    ClassDB::bind_method(D_METHOD("set_bend_stiffness", "value"), &VerletRope::SetBendStiffness);
    ClassDB::bind_method(D_METHOD("get_bend_stiffness"), &VerletRope::GetBendStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bend_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_bend_stiffness", "get_bend_stiffness");

    ClassDB::bind_method(D_METHOD("set_stretch_compliance", "value"), &VerletRope::SetStretchCompliance);
    ClassDB::bind_method(D_METHOD("get_stretch_compliance"), &VerletRope::GetStretchCompliance);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stretch_compliance", PROPERTY_HINT_RANGE,
                              "0.0,0.01,0.0000001,or_greater"),
                 "set_stretch_compliance", "get_stretch_compliance");

    ClassDB::bind_method(D_METHOD("set_bend_compliance", "value"), &VerletRope::SetBendCompliance);
    ClassDB::bind_method(D_METHOD("get_bend_compliance"), &VerletRope::GetBendCompliance);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bend_compliance", PROPERTY_HINT_RANGE,
                              "0.0,0.01,0.0000001,or_greater"),
                 "set_bend_compliance", "get_bend_compliance");

    ClassDB::bind_method(D_METHOD("set_contact_compliance", "value"), &VerletRope::SetContactCompliance);
    ClassDB::bind_method(D_METHOD("get_contact_compliance"), &VerletRope::GetContactCompliance);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_compliance", PROPERTY_HINT_RANGE,
                              "0.0,0.01,0.0000001,or_greater"),
                 "set_contact_compliance", "get_contact_compliance");

    ClassDB::bind_method(D_METHOD("set_max_bend_degrees", "value"), &VerletRope::SetMaxBendDegrees);
    ClassDB::bind_method(D_METHOD("get_max_bend_degrees"), &VerletRope::GetMaxBendDegrees);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_bend_degrees", PROPERTY_HINT_RANGE, "0.0,180.0"),
                 "set_max_bend_degrees", "get_max_bend_degrees");

    ClassDB::bind_method(D_METHOD("set_bend_stiffen_degrees", "value"),
                         &VerletRope::SetBendStiffenDegrees);
    ClassDB::bind_method(D_METHOD("get_bend_stiffen_degrees"),
                         &VerletRope::GetBendStiffenDegrees);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bend_stiffen_degrees",
                              PROPERTY_HINT_RANGE, "0.0,180.0"),
                 "set_bend_stiffen_degrees", "get_bend_stiffen_degrees");

    ClassDB::bind_method(D_METHOD("set_bend_limit_degrees", "value"),
                         &VerletRope::SetBendLimitDegrees);
    ClassDB::bind_method(D_METHOD("get_bend_limit_degrees"),
                         &VerletRope::GetBendLimitDegrees);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bend_limit_degrees",
                              PROPERTY_HINT_RANGE, "0.0,180.0"),
                 "set_bend_limit_degrees", "get_bend_limit_degrees");

    ADD_GROUP("Rendering", "");
    ClassDB::bind_method(D_METHOD("set_tube_radius", "value"), &VerletRope::SetTubeRadius);
    ClassDB::bind_method(D_METHOD("get_tube_radius"), &VerletRope::GetTubeRadius);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tube_radius"), "set_tube_radius", "get_tube_radius");

    ClassDB::bind_method(D_METHOD("set_tube_sides", "value"), &VerletRope::SetTubeSides);
    ClassDB::bind_method(D_METHOD("get_tube_sides"), &VerletRope::GetTubeSides);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "tube_sides"), "set_tube_sides", "get_tube_sides");

    ClassDB::bind_method(D_METHOD("set_smoothing", "value"), &VerletRope::SetSmoothing);
    ClassDB::bind_method(D_METHOD("get_smoothing"), &VerletRope::GetSmoothing);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "smoothing", PROPERTY_HINT_RANGE, "0,3"),
                 "set_smoothing", "get_smoothing");

    ClassDB::bind_method(D_METHOD("set_rope_color", "value"), &VerletRope::SetRopeColor);
    ClassDB::bind_method(D_METHOD("get_rope_color"), &VerletRope::GetRopeColor);
    ADD_PROPERTY(PropertyInfo(Variant::COLOR, "rope_color"), "set_rope_color", "get_rope_color");

    ADD_GROUP("Collision", "");
    ClassDB::bind_method(D_METHOD("set_surface_collision_mask", "value"), &VerletRope::SetSurfaceCollisionMask);
    ClassDB::bind_method(D_METHOD("get_surface_collision_mask"), &VerletRope::GetSurfaceCollisionMask);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS),
                 "set_surface_collision_mask", "get_surface_collision_mask");

    ClassDB::bind_method(D_METHOD("set_collision_radius", "value"), &VerletRope::SetCollisionRadius);
    ClassDB::bind_method(D_METHOD("get_collision_radius"), &VerletRope::GetCollisionRadius);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_radius"), "set_collision_radius", "get_collision_radius");

    ClassDB::bind_method(D_METHOD("set_surface_friction", "value"), &VerletRope::SetSurfaceFriction);
    ClassDB::bind_method(D_METHOD("get_surface_friction"), &VerletRope::GetSurfaceFriction);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_friction", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_surface_friction", "get_surface_friction");

    ClassDB::bind_method(D_METHOD("set_raycast_interval", "value"), &VerletRope::SetRaycastInterval);
    ClassDB::bind_method(D_METHOD("get_raycast_interval"), &VerletRope::GetRaycastInterval);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "raycast_interval"), "set_raycast_interval", "get_raycast_interval");

    ClassDB::bind_method(D_METHOD("set_self_collision", "value"), &VerletRope::SetSelfCollision);
    ClassDB::bind_method(D_METHOD("get_self_collision"), &VerletRope::GetSelfCollision);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "self_collision"), "set_self_collision", "get_self_collision");

    ADD_GROUP("Coupling", "");
    ClassDB::bind_method(D_METHOD("set_anchor_pull", "value"), &VerletRope::SetAnchorPull);
    ClassDB::bind_method(D_METHOD("get_anchor_pull"), &VerletRope::GetAnchorPull);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "anchor_pull"), "set_anchor_pull", "get_anchor_pull");

    ADD_GROUP("End alignment", "");
    ClassDB::bind_method(D_METHOD("set_end_align_stiffness", "value"), &VerletRope::SetEndAlignStiffness);
    ClassDB::bind_method(D_METHOD("get_end_align_stiffness"), &VerletRope::GetEndAlignStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "end_align_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_end_align_stiffness", "get_end_align_stiffness");

    ClassDB::bind_method(D_METHOD("set_plug_exit_axis", "value"), &VerletRope::SetPlugExitAxis);
    ClassDB::bind_method(D_METHOD("get_plug_exit_axis"), &VerletRope::GetPlugExitAxis);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "plug_exit_axis"), "set_plug_exit_axis", "get_plug_exit_axis");

    ClassDB::bind_method(D_METHOD("set_start_exit_axis", "value"), &VerletRope::SetStartExitAxis);
    ClassDB::bind_method(D_METHOD("get_start_exit_axis"), &VerletRope::GetStartExitAxis);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "start_exit_axis"),
                 "set_start_exit_axis", "get_start_exit_axis");

    ClassDB::bind_method(D_METHOD("set_end_exit_axis", "value"), &VerletRope::SetEndExitAxis);
    ClassDB::bind_method(D_METHOD("get_end_exit_axis"), &VerletRope::GetEndExitAxis);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "end_exit_axis"),
                 "set_end_exit_axis", "get_end_exit_axis");

    ClassDB::bind_method(D_METHOD("set_start_endpoint_role", "value"), &VerletRope::SetStartEndpointRole);
    ClassDB::bind_method(D_METHOD("get_start_endpoint_role"), &VerletRope::GetStartEndpointRole);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "start_endpoint_role", PROPERTY_HINT_ENUM,
                              "Auto,Host,Free Plug,Held Plug,Socketed Plug"),
                 "set_start_endpoint_role", "get_start_endpoint_role");

    ClassDB::bind_method(D_METHOD("set_end_endpoint_role", "value"), &VerletRope::SetEndEndpointRole);
    ClassDB::bind_method(D_METHOD("get_end_endpoint_role"), &VerletRope::GetEndEndpointRole);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "end_endpoint_role", PROPERTY_HINT_ENUM,
                              "Auto,Host,Free Plug,Held Plug,Socketed Plug"),
                 "set_end_endpoint_role", "get_end_endpoint_role");

    ClassDB::bind_method(D_METHOD("set_start_anchor_offset", "value"), &VerletRope::SetStartAnchorOffset);
    ClassDB::bind_method(D_METHOD("get_start_anchor_offset"), &VerletRope::GetStartAnchorOffset);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "start_anchor_offset"),
                 "set_start_anchor_offset", "get_start_anchor_offset");

    ClassDB::bind_method(D_METHOD("set_end_anchor_offset", "value"), &VerletRope::SetEndAnchorOffset);
    ClassDB::bind_method(D_METHOD("get_end_anchor_offset"), &VerletRope::GetEndAnchorOffset);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "end_anchor_offset"),
                 "set_end_anchor_offset", "get_end_anchor_offset");

    ClassDB::bind_method(D_METHOD("set_end_stiffness", "value"), &VerletRope::SetEndStiffness);
    ClassDB::bind_method(D_METHOD("get_end_stiffness"), &VerletRope::GetEndStiffness);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "end_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0"),
                 "set_end_stiffness", "get_end_stiffness");

    ClassDB::bind_method(D_METHOD("set_end_stiff_segments", "value"), &VerletRope::SetEndStiffSegments);
    ClassDB::bind_method(D_METHOD("get_end_stiff_segments"), &VerletRope::GetEndStiffSegments);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "end_stiff_segments", PROPERTY_HINT_RANGE, "0,8"),
                 "set_end_stiff_segments", "get_end_stiff_segments");

    ADD_GROUP("Ribbon", "");
    ClassDB::bind_method(D_METHOD("set_ribbon_count", "value"), &VerletRope::SetRibbonCount);
    ClassDB::bind_method(D_METHOD("get_ribbon_count"), &VerletRope::GetRibbonCount);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "ribbon_count", PROPERTY_HINT_RANGE, "1,8"),
                 "set_ribbon_count", "get_ribbon_count");

    ClassDB::bind_method(D_METHOD("set_ribbon_spacing", "value"), &VerletRope::SetRibbonSpacing);
    ClassDB::bind_method(D_METHOD("get_ribbon_spacing"), &VerletRope::GetRibbonSpacing);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ribbon_spacing"), "set_ribbon_spacing", "get_ribbon_spacing");

    ClassDB::bind_method(D_METHOD("set_ribbon_colors", "value"), &VerletRope::SetRibbonColors);
    ClassDB::bind_method(D_METHOD("get_ribbon_colors"), &VerletRope::GetRibbonColors);
    ADD_PROPERTY(PropertyInfo(Variant::PACKED_COLOR_ARRAY, "ribbon_colors"),
                 "set_ribbon_colors", "get_ribbon_colors");

    ClassDB::bind_method(D_METHOD("set_ribbon_axis", "value"), &VerletRope::SetRibbonAxis);
    ClassDB::bind_method(D_METHOD("get_ribbon_axis"), &VerletRope::GetRibbonAxis);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "ribbon_axis"), "set_ribbon_axis", "get_ribbon_axis");

    ADD_GROUP("Fray", "fray_");
    ClassDB::bind_method(D_METHOD("set_fray_segments_start", "value"), &VerletRope::SetFraySegmentsStart);
    ClassDB::bind_method(D_METHOD("get_fray_segments_start"), &VerletRope::GetFraySegmentsStart);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "fray_segments_start", PROPERTY_HINT_RANGE, "0,16"),
                 "set_fray_segments_start", "get_fray_segments_start");

    ClassDB::bind_method(D_METHOD("set_fray_segments_end", "value"), &VerletRope::SetFraySegmentsEnd);
    ClassDB::bind_method(D_METHOD("get_fray_segments_end"), &VerletRope::GetFraySegmentsEnd);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "fray_segments_end", PROPERTY_HINT_RANGE, "0,16"),
                 "set_fray_segments_end", "get_fray_segments_end");

    ClassDB::bind_method(D_METHOD("set_fray_start_groups", "value"), &VerletRope::SetFrayStartGroups);
    ClassDB::bind_method(D_METHOD("get_fray_start_groups"), &VerletRope::GetFrayStartGroups);
    ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "fray_start_groups"),
                 "set_fray_start_groups", "get_fray_start_groups");

    ClassDB::bind_method(D_METHOD("set_fray_end_groups", "value"), &VerletRope::SetFrayEndGroups);
    ClassDB::bind_method(D_METHOD("get_fray_end_groups"), &VerletRope::GetFrayEndGroups);
    ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "fray_end_groups"),
                 "set_fray_end_groups", "get_fray_end_groups");

    ClassDB::bind_method(D_METHOD("set_fray_segment_length", "value"), &VerletRope::SetFraySegmentLength);
    ClassDB::bind_method(D_METHOD("get_fray_segment_length"), &VerletRope::GetFraySegmentLength);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fray_segment_length"),
                 "set_fray_segment_length", "get_fray_segment_length");

    ClassDB::bind_method(D_METHOD("set_fray_taper_segments", "value"), &VerletRope::SetFrayTaperSegments);
    ClassDB::bind_method(D_METHOD("get_fray_taper_segments"), &VerletRope::GetFrayTaperSegments);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "fray_taper_segments", PROPERTY_HINT_RANGE, "0,8"),
                 "set_fray_taper_segments", "get_fray_taper_segments");

    // Anchors — plain properties, assigned from GDScript after instancing.
    ClassDB::bind_method(D_METHOD("set_start_node", "node"), &VerletRope::SetStartNode);
    ClassDB::bind_method(D_METHOD("get_start_node"), &VerletRope::GetStartNode);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "start_node", PROPERTY_HINT_NODE_TYPE, "Node3D",
                              PROPERTY_USAGE_NONE),
                 "set_start_node", "get_start_node");

    ClassDB::bind_method(D_METHOD("set_end_node", "node"), &VerletRope::SetEndNode);
    ClassDB::bind_method(D_METHOD("get_end_node"), &VerletRope::GetEndNode);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "end_node", PROPERTY_HINT_NODE_TYPE, "Node3D",
                              PROPERTY_USAGE_NONE),
                 "set_end_node", "get_end_node");

    // Methods. _init_points keeps its GDScript name (leading underscore and
    // all) because every caller in Scripts/ already spells it that way.
    ClassDB::bind_method(D_METHOD("_init_points"), &VerletRope::InitPoints);
    ClassDB::bind_method(D_METHOD("wake"), &VerletRope::Wake);
    ClassDB::bind_method(D_METHOD("rest_length"), &VerletRope::RestLength);
    ClassDB::bind_method(D_METHOD("get_points"), &VerletRope::GetPoints);
    ClassDB::bind_method(D_METHOD("restore_points", "points"), &VerletRope::RestorePoints);
    ClassDB::bind_method(D_METHOD("get_sleep_metrics"), &VerletRope::GetSleepMetrics);
    ClassDB::bind_method(D_METHOD("nudge_point", "index", "delta"), &VerletRope::NudgePoint);
    ClassDB::bind_method(D_METHOD("point_count"), &VerletRope::PointCount);
    ClassDB::bind_method(D_METHOD("point_position", "index"), &VerletRope::PointPosition);
    ClassDB::bind_method(D_METHOD("set_rope_length", "length"), &VerletRope::SetRopeLength);
    ClassDB::bind_method(D_METHOD("step", "delta"), &VerletRope::Step);
    ClassDB::bind_method(D_METHOD("remesh"), &VerletRope::Remesh);
    ClassDB::bind_method(D_METHOD("is_sleeping"), &VerletRope::IsSleeping);

    // Fray anchors are per group, so they take an index and cannot be plain
    // properties the way start_node/end_node are.
    ClassDB::bind_method(D_METHOD("set_fray_start_node", "group", "node"), &VerletRope::SetFrayStartNode);
    ClassDB::bind_method(D_METHOD("get_fray_start_node", "group"), &VerletRope::GetFrayStartNode);
    ClassDB::bind_method(D_METHOD("set_fray_end_node", "group", "node"), &VerletRope::SetFrayEndNode);
    ClassDB::bind_method(D_METHOD("get_fray_end_node", "group"), &VerletRope::GetFrayEndNode);
    ClassDB::bind_method(D_METHOD("set_fray_start_anchor_offset", "group", "offset"),
                         &VerletRope::SetFrayStartAnchorOffset);
    ClassDB::bind_method(D_METHOD("set_fray_end_anchor_offset", "group", "offset"),
                         &VerletRope::SetFrayEndAnchorOffset);
    ClassDB::bind_method(D_METHOD("get_fray_start_point", "group"), &VerletRope::GetFrayStartPoint);
    ClassDB::bind_method(D_METHOD("get_fray_end_point", "group"), &VerletRope::GetFrayEndPoint);
}

// ── Anchors ─────────────────────────────────────────────────────────────────

void VerletRope::SetStartNode(Node3D *p_node)
{
    const uint64_t old_id = m_start_node_id;
    m_start_node_id = p_node ? p_node->get_instance_id() : 0;
    m_start_cached = p_node;
    if (old_id != m_start_node_id && !m_points.empty())
    {
        m_inv_mass[0] = p_node ? 0.0f : 1.0f;
        Wake();
        RefreshExclusions();
    }
}

Node3D *VerletRope::GetStartNode() const
{
    if (m_start_node_id == 0)
        return nullptr;
    return Object::cast_to<Node3D>(ObjectDB::get_instance(m_start_node_id));
}

void VerletRope::SetEndNode(Node3D *p_node)
{
    const uint64_t old_id = m_end_node_id;
    m_end_node_id = p_node ? p_node->get_instance_id() : 0;
    m_end_cached = p_node;
    if (old_id != m_end_node_id && !m_points.empty())
    {
        const int last = TrunkCount() - 1;
        if (last >= 0 && last < static_cast<int>(m_inv_mass.size()))
            m_inv_mass[last] = p_node ? 0.0f : 1.0f;
        Wake();
        RefreshExclusions();
    }
}

Node3D *VerletRope::GetEndNode() const
{
    if (m_end_node_id == 0)
        return nullptr;
    return Object::cast_to<Node3D>(ObjectDB::get_instance(m_end_node_id));
}

void VerletRope::CacheAnchors()
{
    m_start_cached = GetStartNode();
    m_end_cached = GetEndNode();
    for (FrayChain &fc : m_fray)
        fc.cached = fc.node_id == 0
                        ? nullptr
                        : Object::cast_to<Node3D>(ObjectDB::get_instance(fc.node_id));
}

bool VerletRope::ReconcileAnchors()
{
    Node3D *new_start = GetStartNode();
    Node3D *new_end = GetEndNode();
    bool changed = (m_start_cached != nullptr) != (new_start != nullptr) ||
                   (m_end_cached != nullptr) != (new_end != nullptr);
    if (!m_points.empty())
    {
        if ((m_start_cached != nullptr) != (new_start != nullptr))
            m_inv_mass[0] = new_start ? 0.0f : 1.0f;
        if ((m_end_cached != nullptr) != (new_end != nullptr))
        {
            const int last = TrunkCount() - 1;
            if (last >= 0 && last < static_cast<int>(m_inv_mass.size()))
                m_inv_mass[last] = new_end ? 0.0f : 1.0f;
        }
    }
    m_start_cached = new_start;
    m_end_cached = new_end;
    for (FrayChain &fc : m_fray)
    {
        Node3D *resolved = fc.node_id == 0
                               ? nullptr
                               : Object::cast_to<Node3D>(ObjectDB::get_instance(fc.node_id));
        const bool anchor_changed = (fc.cached != nullptr) != (resolved != nullptr);
        if (anchor_changed && !m_points.empty())
        {
            const int last = fc.first + fc.count - 1;
            if (last >= 0 && last < static_cast<int>(m_inv_mass.size()))
                m_inv_mass[last] = resolved ? 0.0f : 1.0f;
        }
        changed = changed || anchor_changed;
        fc.cached = resolved;
    }
    if (changed)
    {
        RefreshExclusions();
        Wake();
    }
    return changed;
}

// ── Fray anchors ────────────────────────────────────────────────────────────

namespace
{
// The group arrays are written before _init_points knows how many groups there
// are, so they grow on demand rather than being sized up front.
template <typename T> void GrowTo(std::vector<T> &v, int index)
{
    if (index >= static_cast<int>(v.size()))
        v.resize(static_cast<size_t>(index) + 1);
}

Node3D *ResolveId(uint64_t id)
{
    return id == 0 ? nullptr : Object::cast_to<Node3D>(ObjectDB::get_instance(id));
}
} // namespace

void VerletRope::SetFrayStartNode(int p_group, Node3D *p_node)
{
    if (p_group < 0)
        return;
    GrowTo(m_fray_start_ids, p_group);
    m_fray_start_ids[p_group] = p_node ? p_node->get_instance_id() : 0;
    // A chain already built for this group picks the change up immediately.
    int g = 0;
    for (FrayChain &fc : m_fray)
    {
        if (!fc.at_start)
            continue;
        if (g++ == p_group)
        {
            const bool changed = fc.node_id != m_fray_start_ids[p_group];
            fc.node_id = m_fray_start_ids[p_group];
            fc.cached = p_node;
            if (changed && !m_points.empty())
            {
                m_inv_mass[fc.first + fc.count - 1] = p_node ? 0.0f : 1.0f;
                Wake();
                RefreshExclusions();
            }
            break;
        }
    }
}

Node3D *VerletRope::GetFrayStartNode(int p_group) const
{
    if (p_group < 0 || p_group >= static_cast<int>(m_fray_start_ids.size()))
        return nullptr;
    return ResolveId(m_fray_start_ids[p_group]);
}

void VerletRope::SetFrayEndNode(int p_group, Node3D *p_node)
{
    if (p_group < 0)
        return;
    GrowTo(m_fray_end_ids, p_group);
    m_fray_end_ids[p_group] = p_node ? p_node->get_instance_id() : 0;
    int g = 0;
    for (FrayChain &fc : m_fray)
    {
        if (fc.at_start)
            continue;
        if (g++ == p_group)
        {
            const bool changed = fc.node_id != m_fray_end_ids[p_group];
            fc.node_id = m_fray_end_ids[p_group];
            fc.cached = p_node;
            if (changed && !m_points.empty())
            {
                m_inv_mass[fc.first + fc.count - 1] = p_node ? 0.0f : 1.0f;
                Wake();
                RefreshExclusions();
            }
            break;
        }
    }
}

Node3D *VerletRope::GetFrayEndNode(int p_group) const
{
    if (p_group < 0 || p_group >= static_cast<int>(m_fray_end_ids.size()))
        return nullptr;
    return ResolveId(m_fray_end_ids[p_group]);
}

void VerletRope::SetFrayStartAnchorOffset(int p_group, const Vector3 &p_offset)
{
    if (p_group < 0)
        return;
    GrowTo(m_fray_start_offsets, p_group);
    m_fray_start_offsets[p_group] = p_offset;
    int g = 0;
    for (FrayChain &fc : m_fray)
        if (fc.at_start && g++ == p_group)
        {
            fc.offset = p_offset;
            break;
        }
}

void VerletRope::SetFrayEndAnchorOffset(int p_group, const Vector3 &p_offset)
{
    if (p_group < 0)
        return;
    GrowTo(m_fray_end_offsets, p_group);
    m_fray_end_offsets[p_group] = p_offset;
    int g = 0;
    for (FrayChain &fc : m_fray)
        if (!fc.at_start && g++ == p_group)
        {
            fc.offset = p_offset;
            break;
        }
}

// World position of a fray group's terminal particle — where its plug sits.
Vector3 VerletRope::GetFrayStartPoint(int p_group) const
{
    int g = 0;
    for (const FrayChain &fc : m_fray)
        if (fc.at_start && g++ == p_group)
            return m_points[static_cast<size_t>(fc.first) + fc.count - 1];
    return Vector3();
}

Vector3 VerletRope::GetFrayEndPoint(int p_group) const
{
    int g = 0;
    for (const FrayChain &fc : m_fray)
        if (!fc.at_start && g++ == p_group)
            return m_points[static_cast<size_t>(fc.first) + fc.count - 1];
    return Vector3();
}

Vector3 VerletRope::AnchorPoint(Node3D *node, const Vector3 &offset, const Vector3 &fallback) const
{
    return node ? (node->get_global_transform().xform(offset)) : fallback;
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

void VerletRope::_ready()
{
    set_as_top_level(true);
    set_global_transform(Transform3D());

    // InitPoints lays out the particles the topology has to match, so it runs
    // first and rebuilds the mesh itself — BuildMeshTopology sizes from the
    // fray chains it produces.
    InitPoints();

    if (m_surface_collision_mask != 0)
    {
        m_ray_query.instantiate();
        m_ray_query->set_collision_mask(m_surface_collision_mask);
        m_ray_query->set_hit_back_faces(false);
        m_sphere.instantiate();
        // Query slightly beyond the contact distance so a particle RESTING at
        // exactly collision_radius keeps reporting.
        m_sphere->set_radius(m_collision_radius * 1.3);
        m_shape_query.instantiate();
        m_shape_query->set_shape(m_sphere);
        m_shape_query->set_collision_mask(m_surface_collision_mask);
        m_segment_capsule.instantiate();
        m_segment_capsule->set_radius(m_collision_radius * 1.3);
        m_segment_capsule->set_height(m_collision_radius * 2.6);
        m_segment_shape_query.instantiate();
        m_segment_shape_query->set_shape(m_segment_capsule);
        m_segment_shape_query->set_collision_mask(m_surface_collision_mask);
        m_point_query.instantiate();
        m_point_query->set_collision_mask(m_surface_collision_mask);
        RefreshExclusions();
    }
}

// A cord's jacket: its own entry in ribbon_colors, or rope_color when the array
// is short or absent. A plain one-cord cable never touches ribbon_colors.
Color VerletRope::CordColor(int p_cord) const
{
    if (p_cord >= 0 && p_cord < m_ribbon_colors.size())
        return m_ribbon_colors[p_cord];
    return m_rope_color;
}

// One ShaderMaterial per cord. They share the shader resource (ResourceLoader
// caches it) but not the parameter, which is what lets a composite lead run
// yellow/white/red down one node.
void VerletRope::RebuildMaterials()
{
    const int cords = m_ribbon_count > 0 ? m_ribbon_count : 1;
    if (static_cast<int>(m_materials.size()) != cords)
    {
        // Lit PVC jacket — cable.gdshader derives its normal from a CUSTOM0
        // attribute, because the tube has no normal array (positions are
        // re-uploaded every frame through surface_update_vertex_region, and
        // normals would share that buffer).
        Ref<Shader> shader = ResourceLoader::get_singleton()->load(CABLE_SHADER_PATH);
        m_materials.clear();
        m_materials.resize(cords);
        for (int c = 0; c < cords; ++c)
        {
            m_materials[c].instantiate();
            m_materials[c]->set_shader(shader);
        }
    }
    for (int c = 0; c < cords; ++c)
        m_materials[c]->set_shader_parameter("cable_color", CordColor(c));
}

bool VerletRope::CordsShareColour() const
{
    const int cords = m_ribbon_count > 0 ? m_ribbon_count : 1;
    for (int c = 1; c < cords; ++c)
        if (CordColor(c) != CordColor(0))
            return false;
    return true;
}

// A colour change can move a built ribbon between one shared surface and a
// surface per cord (BuildMeshTopology), so the mesh is rebuilt when it does.
void VerletRope::SetRopeColor(const Color &p_color)
{
    m_rope_color = p_color;
    for (size_t c = 0; c < m_materials.size(); ++c)
        m_materials[c]->set_shader_parameter("cable_color", CordColor(static_cast<int>(c)));
    if (m_built_cords > 1 && m_built_merged != CordsShareColour())
        BuildMeshTopology();
}

void VerletRope::SetRibbonColors(const PackedColorArray &p_colors)
{
    m_ribbon_colors = p_colors;
    for (size_t c = 0; c < m_materials.size(); ++c)
        m_materials[c]->set_shader_parameter("cable_color", CordColor(static_cast<int>(c)));
    if (m_built_cords > 1 && m_built_merged != CordsShareColour())
        BuildMeshTopology();
}

// Changing the cord count changes the surface count, so the mesh has to be
// rebuilt; InitPoints notices and does it.
void VerletRope::SetRibbonCount(int p_count)
{
    m_ribbon_count = CLAMP(p_count, 1, 8);
}

// Trunk plus one branch, which is how far the far plug can actually get from the
// near one — not the sum of every branch.
double VerletRope::RestLength() const
{
    double len = m_segment_count * m_segment_length;
    if (m_fray_segments_start > 0)
        len += m_fray_segments_start * FraySegLength();
    if (m_fray_segments_end > 0)
        len += m_fray_segments_end * FraySegLength();
    return len;
}

PackedVector3Array VerletRope::GetPoints() const
{
    PackedVector3Array out;
    out.resize(static_cast<int64_t>(m_points.size()));
    Vector3 *w = out.ptrw();
    for (size_t i = 0; i < m_points.size(); ++i)
        w[i] = m_points[i];
    return out;
}

bool VerletRope::RestorePoints(const PackedVector3Array &p_points)
{
    if (p_points.size() != static_cast<int64_t>(m_points.size()) || m_points.empty())
        return false;
    for (int i = 0; i < p_points.size(); ++i)
    {
        const Vector3 p = p_points[i];
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z))
            return false;
    }
    // Reject corrupt or stale topology rather than injecting an arbitrarily
    // stretched chain. A valid saved lay may be under tension, but four times a
    // segment's rest length is already far beyond any player-produced state.
    for (int s = 0; s < static_cast<int>(m_seg_a.size()); ++s)
    {
        if (p_points[m_seg_a[s]].distance_to(p_points[m_seg_b[s]]) > m_seg_rest[s] * 4.0)
            return false;
    }
    for (int i = 0; i < p_points.size(); ++i)
        m_points[i] = p_points[i];
    m_prev_points = m_points;
    PinAnchors();
    std::fill(m_c_flags.begin(), m_c_flags.end(), 0);
    std::fill(m_mid_contact.begin(), m_mid_contact.end(), 0);
    std::fill(m_stuck_passes.begin(), m_stuck_passes.end(), 0);
    // Validation against the live room is deliberately deferred to the first
    // physics tick, when direct-space queries are legal. DepenetrateLay then
    // repairs a saved cord whose furniture moved through it while loading.
    m_depen_pending = true;
    m_settle_repair_attempted = false;
    Wake();
    m_mesh_dirty = true;
    return true;
}

Dictionary VerletRope::GetSleepMetrics() const
{
    Dictionary out;
    out["max_velocity"] = m_debug_max_velocity;
    out["rms_velocity"] = m_debug_rms_velocity;
    out["stretch_error"] = m_debug_stretch_error;
    out["contact_error"] = m_debug_contact_error;
    out["contact_stable_frames"] = m_contact_stable_frames;
    out["still_frames"] = m_still_frames;
    return out;
}

void VerletRope::NudgePoint(int p_index, const Vector3 &p_delta)
{
    if (p_index < 0 || p_index >= static_cast<int>(m_points.size()) || m_inv_mass[p_index] == 0.0f)
        return;
    m_points[p_index] += p_delta;
    Wake();
}

int VerletRope::PointCount() const
{
    return static_cast<int>(m_points.size());
}

Vector3 VerletRope::PointPosition(int p_index) const
{
    if (p_index < 0 || p_index >= static_cast<int>(m_points.size()))
        return Vector3();
    return m_points[p_index];
}

// Rest distances only — the particle layout, the chains and the contact caches
// are all unaffected by a length change, so this deliberately does not re-init.
void VerletRope::RefreshSegmentRest()
{
    const int trunk_segs = TrunkCount() - 1;
    const double fray_rest = FraySegLength();
    for (size_t s = 0; s < m_seg_rest.size(); ++s)
        m_seg_rest[s] = static_cast<int>(s) < trunk_segs ? m_segment_length : fray_rest;
}

void VerletRope::SetSegmentLength(double p_length)
{
    m_segment_length = p_length;
    RefreshSegmentRest();
}

void VerletRope::SetFraySegmentLength(double p_length)
{
    m_fray_segment_length = p_length;
    RefreshSegmentRest();
}

void VerletRope::SetRopeLength(double p_length)
{
    m_segment_length = std::fmax(p_length, 0.01) / static_cast<double>(m_segment_count);
    RefreshSegmentRest();
    Wake();
}

void VerletRope::Wake()
{
    m_asleep = false;
    m_sleep_environment_frame = 0;
    m_environment_change_polls = 0;
    m_still_frames = 0;
    OpenExcursionWindow();
}

void VerletRope::OpenExcursionWindow()
{
    m_still_frames = 0;
    m_contact_stable_frames = 0;
}

void VerletRope::SleepNow()
{
    m_asleep = true;
    m_sleep_environment_frame = 0;
    m_environment_change_polls = 0;
    // Zero implied velocities so waking doesn't inherit stale motion — and so a
    // rope stopped mid-oscillation doesn't resume it.
    m_prev_points = m_points;

    // A free plug uses a spherical collision shape but its cable anchor sits
    // several centimetres off-centre. Jolt can leave that sphere microscopically
    // rolling on a floor forever: too little motion to keep the rope awake, but
    // enough accumulated anchor drift to wake it again a few frames later. Once
    // the entire rope has met its sleep criterion, latch only its genuinely free
    // plug bodies asleep with it. Mounted controller anchors are plain Node3D
    // children and PlugIsFixed() keeps their ancestor bodies out of this path;
    // held and socketed plugs are fixed for the same reason.
    if (m_start_body != nullptr &&
        EndpointIsFree(ResolveEndpointRole(m_start_cached, m_start_endpoint_role)))
        m_start_body->set_sleeping(true);
    if (m_end_body != nullptr &&
        EndpointIsFree(ResolveEndpointRole(m_end_cached, m_end_endpoint_role)))
        m_end_body->set_sleeping(true);
    for (const FrayChain &fc : m_fray)
        if (fc.body != nullptr && !PlugIsFixed(fc.cached))
            fc.body->set_sleeping(true);
}

// Work out the fray chains at one end and append their particles to the layout.
// Cords are grouped by destination, so `groups` ids are deduplicated in order of
// first appearance; an empty array frays every cord separately. Fills the
// per-cord lateral tracks: where a cord sits along the trunk, and the narrower
// slot it eases into inside its own group.
void VerletRope::BuildFrayChains(int &r_total)
{
    const int cords = m_ribbon_count > 0 ? m_ribbon_count : 1;
    m_fray.clear();
    m_cord_start_chain.assign(cords, -1);
    m_cord_end_chain.assign(cords, -1);
    m_lat_start.assign(cords, 0.0f);
    m_lat_end.assign(cords, 0.0f);
    m_lat_trunk.assign(cords, 0.0f);
    for (int c = 0; c < cords; ++c)
        m_lat_trunk[c] = static_cast<float>(c) - 0.5f * static_cast<float>(cords - 1);

    struct End
    {
        bool at_start;
        int tail;
        const PackedInt32Array *ids;
        int junction;
        std::vector<int> *cord_chain;
        std::vector<float> *lat;
        const std::vector<uint64_t> *nodes;
        const std::vector<Vector3> *offsets;
    };
    const End ends[2] = {
        {true, m_fray_segments_start, &m_fray_start_groups, 0, &m_cord_start_chain, &m_lat_start,
         &m_fray_start_ids, &m_fray_start_offsets},
        {false, m_fray_segments_end, &m_fray_end_groups, TrunkCount() - 1, &m_cord_end_chain,
         &m_lat_end, &m_fray_end_ids, &m_fray_end_offsets},
    };

    for (const End &e : ends)
    {
        if (e.tail <= 0)
            continue;
        int dense[8] = {0};
        int raw_of_group[8] = {0};
        int groups = 0;
        for (int c = 0; c < cords; ++c)
        {
            const int raw = e.ids->size() == 0
                                ? c
                                : (c < e.ids->size() ? static_cast<int>((*e.ids)[c]) : 0);
            int g = -1;
            for (int k = 0; k < groups; ++k)
                if (raw_of_group[k] == raw)
                {
                    g = k;
                    break;
                }
            if (g < 0)
            {
                g = groups;
                raw_of_group[groups++] = raw;
            }
            dense[c] = g;
        }

        int size_of[8] = {0};
        int index_in[8] = {0};
        for (int c = 0; c < cords; ++c)
            index_in[c] = size_of[dense[c]]++;
        for (int c = 0; c < cords; ++c)
            (*e.lat)[c] = static_cast<float>(index_in[c]) -
                          0.5f * static_cast<float>(size_of[dense[c]] - 1);

        const int base = static_cast<int>(m_fray.size());
        for (int g = 0; g < groups; ++g)
        {
            FrayChain fc;
            fc.head = e.junction;
            fc.first = r_total;
            fc.count = e.tail;
            fc.at_start = e.at_start;
            fc.node_id = g < static_cast<int>(e.nodes->size()) ? (*e.nodes)[g] : 0;
            fc.offset = g < static_cast<int>(e.offsets->size()) ? (*e.offsets)[g] : Vector3();
            float lat_sum = 0.0f;
            for (int c = 0; c < cords; ++c)
                if (dense[c] == g)
                    lat_sum += m_lat_trunk[c];
            fc.lat_mean = lat_sum / static_cast<float>(size_of[g]);
            m_fray.push_back(fc);
            r_total += e.tail;
        }
        for (int c = 0; c < cords; ++c)
            (*e.cord_chain)[c] = base + dense[c];
    }
}

void VerletRope::InitPoints()
{
    const int trunk_n = TrunkCount();
    int count = trunk_n;
    BuildFrayChains(count);

    m_points.assign(count, Vector3());
    m_prev_points.assign(count, Vector3());
    m_inv_mass.assign(count, 1.0f);
    m_c_flags.assign(count, 0);
    m_c_p1.assign(count, Vector3());
    m_c_n1.assign(count, Vector3());
    m_c_p2.assign(count, Vector3());
    m_c_n2.assign(count, Vector3());
    m_stuck_passes.assign(count, 0);
    m_self_group.assign(count, 0);
    m_next_seg.assign(count, -1);
    m_active_contact.reserve(count);

    // Segment table. Without a fray this is exactly (i, i+1) over the trunk, so
    // every adjacency-aware pass behaves as it always did.
    m_seg_a.clear();
    m_seg_b.clear();
    m_seg_rest.clear();
    for (int i = 0; i < trunk_n - 1; ++i)
    {
        m_seg_a.push_back(i);
        m_seg_b.push_back(i + 1);
        m_seg_rest.push_back(m_segment_length);
    }
    const double fray_rest = FraySegLength();
    for (const FrayChain &fc : m_fray)
    {
        m_seg_a.push_back(fc.head);
        m_seg_b.push_back(fc.first);
        m_seg_rest.push_back(fray_rest);
        for (int k = 0; k < fc.count - 1; ++k)
        {
            m_seg_a.push_back(fc.first + k);
            m_seg_b.push_back(fc.first + k + 1);
            m_seg_rest.push_back(fray_rest);
        }
    }
    const int seg_count = static_cast<int>(m_seg_a.size());
    for (int s = 0; s < seg_count; ++s)
        if (m_next_seg[m_seg_a[s]] < 0)
            m_next_seg[m_seg_a[s]] = s;
    m_mid_contact.assign(seg_count, 0);
    m_mid_contact_point.assign(seg_count, Vector3());
    m_mid_contact_normal.assign(seg_count, Vector3());
    m_mid_contact_t.assign(seg_count, 0.5f);
    m_mid_contact_point_2.assign(seg_count, Vector3());
    m_mid_contact_normal_2.assign(seg_count, Vector3());
    m_mid_contact_t_2.assign(seg_count, 0.5f);
    m_active_mid.reserve(seg_count);
    m_settle_repair_attempted = false;

    CacheAnchors();
    // How many branches each end has, and where their plugs are. Both decide the
    // trunk's layout below: a frayed end has no anchor of its own, so its
    // junction belongs among its plugs.
    int at_start = 0;
    int at_end = 0;
    Vector3 plug_mid[2];
    int plug_n[2] = {0, 0};
    for (const FrayChain &fc : m_fray)
    {
        const int e = fc.at_start ? 0 : 1;
        (fc.at_start ? at_start : at_end) += 1;
        if (fc.cached != nullptr)
        {
            plug_mid[e] += AnchorPoint(fc.cached, fc.offset, Vector3());
            plug_n[e] += 1;
        }
    }

    // Without a fray these are the old fallbacks exactly. With one, falling back
    // to get_global_position() would be the WORLD ORIGIN — the rope is top_level
    // at identity — so a lead frayed at both ends spawned itself in the middle
    // of the room and 1.5 m underground, on the wrong side of the floor where
    // contact resolution cannot get it back out.
    Vector3 start_pos;
    if (m_start_cached != nullptr)
        start_pos = AnchorPoint(m_start_cached, m_start_anchor_offset, Vector3());
    else if (plug_n[0] > 0)
        start_pos = plug_mid[0] / static_cast<real_t>(plug_n[0]);
    else
        start_pos = get_global_position();

    Vector3 end_pos;
    if (m_end_cached != nullptr)
        end_pos = AnchorPoint(m_end_cached, m_end_anchor_offset, Vector3());
    else if (plug_n[1] > 0)
        end_pos = plug_mid[1] / static_cast<real_t>(plug_n[1]);
    else
        end_pos = start_pos + Vector3(0, -m_segment_count * m_segment_length, 0);

    for (int i = 0; i < trunk_n; ++i)
    {
        const double t = trunk_n > 1 ? static_cast<double>(i) / static_cast<double>(trunk_n - 1) : 0.0;
        m_points[i] = start_pos.lerp(end_pos, t);
        m_prev_points[i] = m_points[i];
    }
    // Each branch is seeded straight from the junction to its plug, or hanging
    // if it has none — the same rule the trunk uses when end_node is null. An
    // unanchored branch also starts out at its cords' place across the ribbon,
    // so two of them don't begin life exactly on top of each other.
    Vector3 ribbon_dir = m_ribbon_axis;
    if (m_start_cached != nullptr)
        ribbon_dir = m_start_cached->get_global_transform().basis.orthonormalized().xform(m_ribbon_axis);
    ribbon_dir = ribbon_dir.length_squared() > 1e-12 ? ribbon_dir.normalized() : Vector3(1, 0, 0);
    for (const FrayChain &fc : m_fray)
    {
        const Vector3 from = m_points[fc.head];
        const Vector3 hang = from + Vector3(0, -fc.count * FraySegLength(), 0) +
                             ribbon_dir * (fc.lat_mean * CordPitch());
        const Vector3 to = AnchorPoint(fc.cached, fc.offset, hang);
        for (int k = 0; k < fc.count; ++k)
        {
            const double t = static_cast<double>(k + 1) / static_cast<double>(fc.count);
            m_points[fc.first + k] = from.lerp(to, t);
            m_prev_points[fc.first + k] = m_points[fc.first + k];
        }
        if (fc.cached)
            m_inv_mass[fc.first + fc.count - 1] = 0.0f;
    }

    // Particle 0 has always been pinned unconditionally, because it was always a
    // host attach point bolted to a device. It stops being one the moment the
    // start end frays: then it is an unsupported breakout that the branches
    // carry, and pinning it welds the cable to wherever start_pos landed. Left
    // exactly as it was when there is no start fray.
    if (m_start_cached != nullptr || at_start == 0)
        m_inv_mass[0] = 0.0f;
    if (m_end_cached)
        m_inv_mass[trunk_n - 1] = 0.0f;

    // A junction takes one stretch constraint from the trunk and one from every
    // branch, so at equal inverse mass the branches outvote the trunk and the
    // joint chatters. Weighting it like the small moulded boot that is really
    // there settles it. A pinned junction is left alone.
    if (at_start > 0 && m_inv_mass[0] != 0.0f)
        m_inv_mass[0] = 1.0f / static_cast<float>(1 + at_start);
    if (at_end > 0 && m_inv_mass[trunk_n - 1] != 0.0f)
        m_inv_mass[trunk_n - 1] = 1.0f / static_cast<float>(1 + at_end);

    // Self-collision exemptions around each junction, where the branch heads and
    // the trunk's end are coincident by construction rather than by collision.
    if (at_start > 0)
    {
        m_self_group[0] = 1;
        if (trunk_n > 1)
            m_self_group[1] = 1;
    }
    if (at_end > 0)
    {
        m_self_group[trunk_n - 1] = 2;
        if (trunk_n > 1)
            m_self_group[trunk_n - 2] = 2;
    }
    for (const FrayChain &fc : m_fray)
    {
        const uint8_t id = fc.at_start ? 1 : 2;
        for (int k = 0; k < fc.count && k < 2; ++k)
            m_self_group[fc.first + k] = id;
    }

    // The surface count and the ring count both follow from the layout above, so
    // a rope resized after _ready rebuilds its mesh here rather than meshing a
    // stale ring buffer. retro_controller.gd::_resize_cable() does exactly that.
    const int cords = m_ribbon_count > 0 ? m_ribbon_count : 1;
    const int rings = (CordPointCount() - 1) * Subdiv() + 1;
    if (cords != m_built_cords || rings != m_built_rings || m_tube_sides != m_built_sides)
        BuildMeshTopology();

    Wake();
    m_sleep_anchor_start = AnchorPoint(m_start_cached, m_start_anchor_offset, start_pos);
    m_sleep_anchor_end = AnchorPoint(m_end_cached, m_end_anchor_offset, end_pos);
    for (FrayChain &fc : m_fray)
        fc.sleep_pos = AnchorPoint(fc.cached, fc.offset, m_points[fc.first + fc.count - 1]);
    RefreshExclusions();
    // The straight lay above ignores the world, so furniture on the line leaves
    // particles buried in it. Deferred to the first Step, where space-state
    // queries are legal — InitPoints also runs from _ready and from setters.
    m_depen_pending = true;
    // Resize-and-seed: SnapshotRenderState detects the length change and fills
    // both history buffers from the fresh points.
    m_curr_render.clear();
    SnapshotRenderState();
}

// Exclude the plug body and the host machine's body from rope collision — the
// anchor points sit at/inside those colliders and would jitter forever. Also
// caches the anchors' RigidBody3D ancestors for two-way coupling.
void VerletRope::RefreshExclusions()
{
    TypedArray<RID> rids;
    m_start_body = nullptr;
    m_end_body = nullptr;
    // Index 0 is the trunk's start, 1 its end, and 2+g fray chain g — the loop
    // below maps a_idx back onto those slots when it caches the rigidbodies.
    std::vector<Node3D *> anchors;
    anchors.reserve(2 + m_fray.size());
    anchors.push_back(GetStartNode());
    anchors.push_back(GetEndNode());
    for (FrayChain &fc : m_fray)
    {
        fc.body = nullptr;
        anchors.push_back(fc.cached);
    }
    for (size_t a_idx = 0; a_idx < anchors.size(); ++a_idx)
    {
        Node *n = anchors[a_idx];
        while (n != nullptr)
        {
            CollisionObject3D *co = Object::cast_to<CollisionObject3D>(n);
            if (co != nullptr)
            {
                rids.push_back(co->get_rid());
                RigidBody3D *rb = Object::cast_to<RigidBody3D>(n);
                if (rb != nullptr)
                {
                    if (a_idx == 0)
                        m_start_body = rb;
                    else if (a_idx == 1)
                        m_end_body = rb;
                    else
                        m_fray[a_idx - 2].body = rb;
                }
                break;
            }
            n = n->get_parent();
        }
    }
    if (m_ray_query.is_valid())
        m_ray_query->set_exclude(rids);
    if (m_shape_query.is_valid())
        m_shape_query->set_exclude(rids);
    if (m_segment_shape_query.is_valid())
        m_segment_shape_query->set_exclude(rids);
    if (m_point_query.is_valid())
        m_point_query->set_exclude(rids);
}

bool VerletRope::AnchorsMoved() const
{
    if (AnchorPoint(m_start_cached, m_start_anchor_offset, m_sleep_anchor_start)
            .distance_squared_to(m_sleep_anchor_start) > WAKE_ANCHOR_EPS_SQ)
        return true;
    if (AnchorPoint(m_end_cached, m_end_anchor_offset, m_sleep_anchor_end)
            .distance_squared_to(m_sleep_anchor_end) > WAKE_ANCHOR_EPS_SQ)
        return true;
    for (const FrayChain &fc : m_fray)
        if (AnchorPoint(fc.cached, fc.offset, fc.sleep_pos).distance_squared_to(fc.sleep_pos) >
            WAKE_ANCHOR_EPS_SQ)
            return true;
    return false;
}

} // namespace Xenu
