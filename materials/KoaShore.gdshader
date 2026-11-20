shader_type spatial;

uniform vec4 volcanic_charcoal : source_color = vec4(0.258824, 0.239216, 0.219608, 1.0);
uniform vec4 volcanic_earth : source_color = vec4(0.545098, 0.396078, 0.290196, 1.0);
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

/* Terrain3D generated terrain shader, kept intact through the normal calculation.
 * The Koa shoreline block at the end of fragment() repaints the coastal band:
 * black basalt sand, lava-rock shelves, and a noise-broken grass edge, plus a
 * wave-driven wet sheen. Vertex displacement and the height maps are unchanged.
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >>14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >>27u & 0x1Fu)
#define DECODE_OVER(control) int(control >>22u & 0x1Fu)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
group_uniforms private;
uniform vec3 _target_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform float _subdiv = 1.f;
uniform float _tessellation_level = 0.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
#define MAX_REGIONS 1024

uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_ao_affect_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
#define FILTER_LINEAR
#define FILTER_METHOD filter_linear_mipmap_anisotropic

uniform highp sampler2DArray _color_maps : source_color, FILTER_METHOD, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, FILTER_METHOD, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, FILTER_METHOD, repeat_enable;
uniform vec3 _light_direction = vec3(0., 0., 0);
uniform vec3 _light_color : source_color = vec3(1.0, 1.0, .735);
group_uniforms;

// Public uniforms
group_uniforms general_uniforms;
uniform bool flat_terrain_normals = false;
uniform float distant_normal_scale : hint_range(1.0, 10.0, 0.1) = 2.0;
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
group_uniforms;

group_uniforms macro_variation;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.)  = 0.333;
uniform highp sampler2D noise_texture : source_color, FILTER_METHOD, repeat_enable;
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04; // Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x
group_uniforms;


group_uniforms mipmaps;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;
uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
group_uniforms;


// Varyings & Types

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao;
	float ao_affect;
	float total_weight;
};

uniform sampler2D volcanic_deposit : filter_linear, repeat_disable;
uniform float volcanic_glow = 0.0;
varying vec3 v_vertex;
varying float v_vertex_xz_dist;
varying vec3 v_camera_pos;

////////////////////////
// Vertex
////////////////////////

// Takes in world space XZ (UV) coordinates
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv) {
	vec2 r_uv = round(uv);
	ivec2 pos = ivec2(floor(r_uv * _region_texel_size)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int map_val = _region_map[pos.y * _region_map_size + pos.x];
	int raw_index = map_val - 1;
	// Real regions limited by max_regions
	int is_region = bounds * int(raw_index >= 0) * int(raw_index < MAX_REGIONS);
	// Editor dummies are negative; keep them != -1 so the shader still sees a region
	int is_dummy = bounds * int(map_val < 0);
	int layer_index = is_region * raw_index
	               + is_dummy * (map_val - 1)
	               - (1 - is_region - is_dummy);
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int map_val = _region_map[pos.y * _region_map_size + pos.x];
	int raw_index = map_val - 1;
	int is_region = bounds * int(raw_index >= 0) * int(raw_index < MAX_REGIONS);
	int is_dummy = bounds * int(map_val < 0);
	int layer_index = is_region * raw_index
	               + is_dummy * (map_val - 1)
	               - (1 - is_region - is_dummy);
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

float interpolated_height(vec2 pos) {
	const vec2 offsets = vec2(0, 1);
	vec2 index_id = floor(pos);
	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);
	float h0 = texelFetch(_height_maps, index[0], 0).r;
	float h1 = texelFetch(_height_maps, index[1], 0).r;
	float h2 = texelFetch(_height_maps, index[2], 0).r;
	float h3 = texelFetch(_height_maps, index[3], 0).r;
	vec2 f = fract(pos);
	vec2 i = 1.0 - f;
	vec4 w = vec4(i.x * f.y, f.x * f.y, f.x * i.y, i.x * i.y);
	float h = h0 * w[0] + h1 * w[1] + h2 * w[2] + h3 * w[3];
	return h;
}

// Takes in world space XZ (UV) and returns if the coordinate should be part of the NONE background.
bool is_none_bg(const vec2 uv) {
	ivec4 regions = ivec4(
		get_index_coord(uv - vec2(0.5, 0.0)).z,
		get_index_coord(uv - vec2(0.0, 0.5)).z,
		get_index_coord(uv + vec2(1.0, 0.0)).z,
		get_index_coord(uv + vec2(0.0, 1.0)).z);
	return any(equal(regions, ivec4(-1)));
}


void vertex() {
	// Save Camera Position to varying for access in later functions
	v_camera_pos = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;

	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Distance from target node to vertex on a flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _target_pos.xz);

	// Geomorph vertex across clipmap LODs, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float inv_scale = 1.0 / scale;
	float max_xz = max(abs(v_vertex.x - _target_pos.x), abs(v_vertex.z - _target_pos.z));
	float vertex_lerp = smoothstep(0.0, 1.0, (max_xz * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
	vec2 vertex_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
		// Shift from regular to symmetric
		mix(vertex_fract, vec2(vertex_fract.x, -vertex_fract.y),
			round(fract(round(mod(v_vertex.z * inv_scale, 4.0)) *
			round(mod(v_vertex.x * inv_scale, 4.0)) * 0.25))) :
		// Symmetric shift
		vertex_fract * round((fract(v_vertex.xz * 0.25 * inv_scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in region space. 0-1 covers 1 region, 1-2 is the next region, etc.
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_index_coord(start_pos);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	vec3 displacement = vec3(0.);
	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && (hole
		|| (_background_mode == 0u && is_none_bg(UV))
		)){
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height.
		float h;
		// This branch is static for each of the clipmap segments
		// Interpolated reads only occur where sub-texel values are required.
		if (scale < _vertex_spacing) {
			h = interpolated_height(UV);
		} else {
			ivec3 coord_a = get_index_coord(start_pos);
			ivec3 coord_b = get_index_coord(end_pos);
			h = mix(texelFetch(_height_maps, coord_a, 0).r, texelFetch(_height_maps, coord_b, 0).r, vertex_lerp);
		}

		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	// Include displacement without modifying v_vertex.
	VERTEX = (VIEW_MATRIX * vec4(v_vertex + displacement, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// 2-4 lookups ( 2-6 with dual scaling )
void accumulate_material(vec3 base_ddx, vec3 base_ddy, const mat3 TNB, const float weight, const ivec3 index,
			const uint control, const vec2 texture_weight, const ivec2 texture_id, const vec3 i_normal,
			float h, inout material mat) {

	// Applying scaling before projection reduces the number of multiplys ops required.
	vec3 i_vertex = v_vertex;

	// Control map scale
	float control_scale = DECODE_SCALE(control);
	base_ddx *= control_scale;
	base_ddy *= control_scale;
	i_vertex *= control_scale;
	h *= control_scale;

	// Index position for detiling.
	vec2 i_pos = fma(_region_locations[index.z], vec2(_region_size), vec2(index.xy));
	i_pos *= _vertex_spacing * control_scale;

	// Projection
	vec2 i_uv = i_vertex.xz;
	vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
	mat2 p_align = mat2(1.);
	if (i_normal.y <= 0.7071067811865475) { // sqrt(0.5)
		// Projected normal map alignment matrix
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		// Fast 45 degree snapping https://iquilezles.org/articles/noatan/
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765); // sqrt(1.0 + sqrt(0.5))
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0; // sqrt(0.5)
		xz = vec2(-xz.y, xz.x);
		i_pos = floor(vec2(dot(i_pos, xz), -h));
		i_uv = vec2(dot(i_vertex.xz, xz), -i_vertex.y);
		#ifndef IS_DISPLACEMENT_BUFFER
		i_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		i_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
		#endif
	}


	// Control map rotation. Must be applied seperatley from detiling to maintain UV continuity.
	float c_angle = DECODE_ANGLE(control);
	vec2 c_cs_angle = vec2(cos(c_angle), sin(c_angle));
	i_uv = rotate_vec2(i_uv, c_cs_angle);
	i_pos = rotate_vec2(i_pos, c_cs_angle);

	// Blend adjustment of Higher ID from Lower ID normal map in world space.
	float world_normal = 1.;
	// mat3 multiply, reduced to 2x fma and 1x mult.
	#define FAST_WORLD_NORMAL(n) fma(TNB[0], vec3(n.x), fma(TNB[2], vec3(n.z), TNB[1] * vec3(n.y)))
	
	float blend = DECODE_BLEND(control); // only used for branching.
	float sharpness = fma(60., blend_sharpness, 4.);


	// 1st Texture Asset ID
	if (blend < 1.0 
			) {
		int id = texture_id[0];
		float id_w = texture_weight[0];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = i_dd * id_scale;

		// Detiling and Control map rotation
		vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		// Unpack and rotate normal map.
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		float ao = length(nrm.xyz) * 2.0 - 1.0;
		ao = mix(ao * ao * _texture_ao_strength_array[id] + 1.0 - _texture_ao_strength_array[id], 1.0, alb.a * alb.a);
		nrm.xyz = normalize(nrm.xyz);
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

		world_normal = FAST_WORLD_NORMAL(nrm).y;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a)) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao = fma(ao, id_weight, mat.ao);
		mat.ao_affect = fma(_texture_ao_affect_array[id], id_weight, mat.ao_affect);
		mat.total_weight += id_weight;
	}

	// 2nd Texture Asset ID
	if (blend > 0.0 && texture_id[1] != texture_id[0]
		) {
		int id = texture_id[1];
		float id_w = texture_weight[1];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = i_dd * id_scale;

		// Detiling and Control map rotation
		vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		// Unpack and rotate normal map.
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		float ao = length(nrm.xyz) * 2.0 - 1.0;
		ao = mix(ao * ao * _texture_ao_strength_array[id] + 1.0 - _texture_ao_strength_array[id], 1.0, alb.a * alb.a);
		nrm.xyz = normalize(nrm.xyz);
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a * clamp(world_normal, 0., 1.))) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao = fma(ao, id_weight, mat.ao);
		mat.ao_affect = fma(_texture_ao_affect_array[id], id_weight, mat.ao_affect);
		mat.total_weight += id_weight;
	}
}

// Height from a provided index avoids repeating the region map lookup.
// index_id & offset are still required for the world-background blend path.
float get_height(const ivec3 index, const vec2 index_id, const vec2 offset) {
	float height = texelFetch(_height_maps, index, 0).r;
	return height;
}

float get_height(const vec2 index_id, const vec2 offset) {
	return get_height(get_index_coord(index_id + offset), index_id, offset);
}


// --- Koa shoreline ----------------------------------------------------------
// World-space breakup for the sand, independent of the painted control map.

float coast_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float coast_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = coast_hash(i);
	float b = coast_hash(i + vec2(1.0, 0.0));
	float c = coast_hash(i + vec2(0.0, 1.0));
	float d = coast_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float coast_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * coast_noise(p);
		p = p * 2.03 + vec2(13.1, 7.7);
		a *= 0.5;
	}
	return v;
}

float coast_height_at(vec2 world_xz) {
	ivec3 tile = get_index_coord(world_xz * _vertex_density);
	return tile.z < 0 ? -48.0 : texelFetch(_height_maps, tile, 0).r;
}

// Metres to the nearest water along 8 bearings. 0 when this point is already wet.
float coast_shore_distance(vec2 world_xz, float here) {
	if (here < 0.08) {
		return 0.0;
	}
	float best = 56.0;
	for (int i = 0; i < 8; i++) {
		float ang = float(i) * 0.78539816;
		vec2 dir = vec2(cos(ang), sin(ang));
		float prev_h = here;
		float prev_d = 0.0;
		for (int s = 0; s < 4; s++) {
			float d = float(s + 1) * 10.0;
			float hh = coast_height_at(world_xz + dir * d);
			if (hh < 0.05) {
				float span = max(prev_h - hh, 0.001);
				float t = clamp((prev_h - 0.05) / span, 0.0, 1.0);
				best = min(best, mix(prev_d, d, t));
				break;
			}
			prev_h = hh;
			prev_d = d;
		}
	}
	return best;
}

vec4 coast_albedo(int id, vec2 world_xz, vec2 ddx, vec2 ddy) {
	float sc = _texture_uv_scale_array[id];
	vec2 uv = world_xz * sc;
	vec2 cell = floor(uv);
	float ang = coast_hash(cell) * 6.2831853;
	vec2 cs = vec2(cos(ang), sin(ang));
	vec2 local = uv - cell - 0.5;
	vec2 ruv = vec2(cs.x * local.x - cs.y * local.y, cs.y * local.x + cs.x * local.y) + cell + 0.5;
	vec4 alb = textureGrad(_texture_array_albedo, vec3(ruv, float(id)), ddx * sc, ddy * sc);
	alb.rgb *= _texture_color_array[id].rgb;
	return alb;
}

vec4 coast_normal(int id, vec2 world_xz, vec2 ddx, vec2 ddy) {
	float sc = _texture_uv_scale_array[id];
	vec2 uv = world_xz * sc;
	vec2 cell = floor(uv);
	float ang = coast_hash(cell + vec2(4.0, 1.0)) * 6.2831853;
	vec2 cs = vec2(cos(ang), sin(ang));
	vec2 local = uv - cell - 0.5;
	vec2 ruv = vec2(cs.x * local.x - cs.y * local.y, cs.y * local.x + cs.x * local.y) + cell + 0.5;
	return textureGrad(_texture_array_normal, vec3(ruv, float(id)), ddx * sc, ddy * sc);
}


void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
	vec3 region_uv = get_index_uv(uv2);
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = min(fract(uv), 1.0 - 1e-7);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	ivec3 index[4];
	// Control map lookups
	// Fast path: when the (0,0) corner is at least two texels inside a region
	// every sample needed for this cell (offsets 0..2) shares the same
	// layer and needs only integer arithmetic; no region map lookup or mod.
	// Slow path: Borders, missing regions, editor dummies and negative coordinates
	// stay on the original slow per-lookup path.
	index[3] = get_index_coord(index_id + offsets.xx); // (0,0)
	bool idx_fast = index[3].z >= 0 && max(index[3].x, index[3].y) < int(_region_size) - 2;
	if (idx_fast) {
		index[0] = index[3] + ivec3(0, 1, 0); // (0,1)
		index[1] = index[3] + ivec3(1, 1, 0); // (1,1)
		index[2] = index[3] + ivec3(1, 0, 0); // (1,0)
	} else {
		index[0] = get_index_coord(index_id + offsets.xy);
		index[1] = get_index_coord(index_id + offsets.yy);
		index[2] = get_index_coord(index_id + offsets.yx);
	}
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 4.0 && any(greaterThan(ivec4(index[0].z, index[1].z, index[2].z, index[3].z), ivec4(-1)));

	// Terrain normals
	vec3 index_normal[4];
	float h[4];
	// Allows for additional derivatives, eg world background, brush previews etc
	float u = 0.0;
	float v = 0.0;


	h[3] = get_height(index[3], index_id, offsets.xx); // (0,0)
	h[2] = get_height(index[2], index_id, offsets.yx); // (1,0)
	h[0] = get_height(index[0], index_id, offsets.xy); // (0,1)
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing, h[3] - h[0] + v));

	// Set flat world normal - overwritten if bilerp is true
	vec3 w_normal = index_normal[3];

	// Adjust derivatives for mipmap bias and depth blur effect
	float bias = mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (v_vertex_xz_dist - bias_distance) * DIV_1024));
	base_ddx *= bias;
	base_ddy *= bias;

	// Color map
	vec4 color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP_DEF;

	// Branching smooth normals and manually interpolated color map - fixes cross region artifacts
	if (bilerp) {
		// 4 lookups if linear filtering, else 1 lookup.
		vec4 col_map[4];
		col_map[3] = index[3].z > -1 ? texelFetch(_color_maps, index[3], 0) : COLOR_MAP_DEF;
		#ifdef FILTER_LINEAR
		col_map[0] = index[0].z > -1 ? texelFetch(_color_maps, index[0], 0) : COLOR_MAP_DEF;
		col_map[1] = index[1].z > -1 ? texelFetch(_color_maps, index[1], 0) : COLOR_MAP_DEF;
		col_map[2] = index[2].z > -1 ? texelFetch(_color_maps, index[2], 0) : COLOR_MAP_DEF;

		color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;
		#else
		color_map = col_map[3];
		#endif

		// 5 lookups
		// Fetch the additional required height values for smooth normals
		// Fast path: the four additional locations are simple offsets of index[3];
		// Slow path: fall back to full region lookup
		h[1] = get_height(index[1], index_id, offsets.yy); // (1,1)

		ivec3 i4, i5, i6, i7;
		if (idx_fast) {
			i4 = index[3] + ivec3(1, 2, 0); // (1,2)
			i5 = index[3] + ivec3(2, 1, 0); // (2,1)
			i6 = index[3] + ivec3(2, 0, 0); // (2,0)
			i7 = index[3] + ivec3(0, 2, 0); // (0,2)
		} else {
			i4 = get_index_coord(index_id + offsets.yz);
			i5 = get_index_coord(index_id + offsets.zy);
			i6 = get_index_coord(index_id + offsets.zx);
			i7 = get_index_coord(index_id + offsets.xz);
		}

		float h_4 = get_height(i4, index_id, offsets.yz);
		float h_5 = get_height(i5, index_id, offsets.zy);
		float h_6 = get_height(i6, index_id, offsets.zx);
		float h_7 = get_height(i7, index_id, offsets.xz);

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing, h[0] - h_7 + v));
		index_normal[1] = normalize(vec3(h[1] - h_5 + u, _vertex_spacing, h[1] - h_4 + v));
		index_normal[2] = normalize(vec3(h[2] - h_6 + u, _vertex_spacing, h[2] - h[1] + v));

		// Set interpolated world normal
		w_normal =
			index_normal[0] * weights[0] +
			index_normal[1] * weights[1] +
			index_normal[2] * weights[2] +
			index_normal[3] * weights[3] ;
	}

	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	mat3 TNB = mat3(w_tangent, w_normal, w_binormal);

	// Apply terrain normals
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX), dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	} else {
		NORMAL = mat3(VIEW_MATRIX) * w_normal;
		TANGENT = mat3(VIEW_MATRIX) * w_tangent;
		BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	}

	// Get index control data
	// 1 - 4 lookups
	uvec4 control = uvec4(floatBitsToUint(texelFetch(_control_maps, index[3], 0).r));
	if (bilerp) {
		control = uvec4(
		floatBitsToUint(texelFetch(_control_maps, index[0], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[1], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[2], 0).r),
		control[3]);
	}


	// Texture weights
	// Vectorised Deocode of all texture IDs, then swizzle to per index mapping.
	// Passed to accumulate_material to avoid repeated decoding.
	ivec4 t_id[2] = {ivec4(control >> uvec4(27u) & uvec4(0x1Fu)),
		ivec4(control >> uvec4(22u) & uvec4(0x1Fu))};
	ivec2 texture_ids[4] = ivec2[4](
		ivec2(t_id[0].x, t_id[1].x),
		ivec2(t_id[0].y, t_id[1].y),
		ivec2(t_id[0].z, t_id[1].z),
		ivec2(t_id[0].w, t_id[1].w));

	// uninterpolated weights.
	vec4 weights_id_1 = vec4(control >> uvec4(14u) & uvec4(0xFFu)) * DIV_255;
	vec4 weights_id_0 = 1.0 - weights_id_1;
	vec2 t_weights[4] = vec2[4](
				vec2(weights_id_0[0], weights_id_1[0]),
				vec2(weights_id_0[1], weights_id_1[1]),
				vec2(weights_id_0[2], weights_id_1[2]),
				vec2(weights_id_0[3], weights_id_1[3]));
	// interpolated weights
	if (bilerp) {
		t_weights = {vec2(0), vec2(0), vec2(0), vec2(0)};
		weights_id_0 *= weights;
		weights_id_1 *= weights;
		for (int i = 0; i < 4; i++) {
			vec2 w_0 = vec2(weights_id_0[i]);
			vec2 w_1 = vec2(weights_id_1[i]);
			ivec2 id_0 = texture_ids[i].xx;
			ivec2 id_1 = texture_ids[i].yy;
			t_weights[0] += fma(w_0, vec2(equal(texture_ids[0], id_0)), w_1 * vec2(equal(texture_ids[0], id_1)));
			t_weights[1] += fma(w_0, vec2(equal(texture_ids[1], id_0)), w_1 * vec2(equal(texture_ids[1], id_1)));
			t_weights[2] += fma(w_0, vec2(equal(texture_ids[2], id_0)), w_1 * vec2(equal(texture_ids[2], id_1)));
			t_weights[3] += fma(w_0, vec2(equal(texture_ids[3], id_0)), w_1 * vec2(equal(texture_ids[3], id_1)));
		}
	}

	// Struct to accumulate all texture data.
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., 0.);

	// 2 - 4 lookups, 2 - 6 if dual scale texture
	accumulate_material(base_ddx, base_ddy, TNB, weights[3], index[3], control[3], t_weights[3],
		texture_ids[3], index_normal[3], h[3], mat);

	// 6 - 12 lookups, 6 - 18 if dual scale texture
	if (bilerp) {
		accumulate_material(base_ddx, base_ddy, TNB, weights[2], index[2], control[2], t_weights[2],
			texture_ids[2], index_normal[2], h[2], mat);
		accumulate_material(base_ddx, base_ddy, TNB, weights[1], index[1], control[1], t_weights[1],
			texture_ids[1], index_normal[1], h[1], mat);
		accumulate_material(base_ddx, base_ddy, TNB, weights[0], index[0], control[0], t_weights[0],
			texture_ids[0], index_normal[0], h[0], mat);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / max(mat.total_weight, 1e-8);
	mat.albedo_height *= weight_inv;
	mat.normal_rough *= weight_inv;
	mat.normal_map_depth *= weight_inv;
	mat.ao *= weight_inv;
	mat.ao_affect *= weight_inv;

	vec3 normal_map = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	float distant_normal_amplifier = clamp(max(length(base_ddx.xz), length(base_ddy.xz)), 1., distant_normal_scale);
	mat.normal_map_depth *= distant_normal_amplifier;

		// Macro variation. 2 lookups
	{
		float noise1 = texture(noise_texture, rotate_vec2(fma(uv, vec2(noise1_scale * .1), noise1_offset) , vec2(cos(noise1_angle), sin(noise1_angle)))).r;
		float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
		vec3 macrov = mix(macro_variation1, vec3(1.), noise1);
		macrov *= mix(macro_variation2, vec3(1.), noise2);
		mat.albedo_height.rgb *= mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
	}


	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range, clamped to Godot roughness values 
	float wetness = fma(color_map.a, -2., 1.);
	float roughness = clamp(mat.normal_rough.a - wetness, 0., 1.);
	
	// Specular w/ non-light-facing suppression. Apply wetness after so it reflects the sky after sunset
	float terrain_facing_light = clamp(dot(w_normal, normalize(_light_direction)), 0.0, 1.0);
	float specular = 1. - mat.normal_rough.a;
	specular *= mix(0.0, 1.0, terrain_facing_light);
	specular = clamp(specular + wetness, 0., 1.);

	// Painted material, then the coastal band overrides the beach only.
	vec3 painted_albedo = mat.albedo_height.rgb * color_map.rgb;
	vec3 painted_normal = normal_map;
	float painted_rough = roughness;
	float painted_spec = specular;

	float height = v_vertex.y;
	vec2 world_xz = v_vertex.xz;
	float slope = clamp(1.0 - w_normal.y, 0.0, 1.0);
	vec3 albedo = painted_albedo;
	vec3 nrm = painted_normal;
	float rough = painted_rough;
	float spec = painted_spec;
	// The expensive shoreline survey contributes only within reach of sea level.
	if (height < 64.0 && height > -12.0) {
		float dist = coast_shore_distance(world_xz, height);
		float cavity = clamp((
			coast_height_at(world_xz + vec2(3.5, 0.0)) +
			coast_height_at(world_xz + vec2(-3.5, 0.0)) +
			coast_height_at(world_xz + vec2(0.0, 3.5)) +
			coast_height_at(world_xz + vec2(0.0, -3.5))) * 0.25 - height, 0.0, 1.2);
		cavity = clamp(cavity * 1.15, 0.0, 1.0);

		float n_edge = coast_fbm(world_xz * 0.031);
		float n_break = coast_fbm(world_xz * 0.09 + vec2(6.0, 2.0));
		// Sand reaches farther on the flat and pulls back on slopes. Noise keeps the edge off a contour line.
		float sand_edge = mix(16.0, 42.0, n_edge) - slope * 22.0 + cavity * 9.0 + (n_break - 0.5) * 8.0;
		float sand_w = 1.0 - smoothstep(sand_edge - 5.0, sand_edge + 4.0, dist);
		sand_w *= 1.0 - smoothstep(0.18, 0.58, slope);
		sand_w *= 1.0 - smoothstep(3.6, 8.5, height);
		// Shallow seabed in front of the beach stays sand, so the water doesn't reveal a different material.
		sand_w = max(sand_w, (1.0 - smoothstep(0.2, 5.5, -height)) * (1.0 - smoothstep(0.22, 0.62, slope)));
		// Sand settles into pockets in the rock.
		sand_w = max(sand_w, cavity * (1.0 - smoothstep(1.5, 10.0, height)) * (1.0 - smoothstep(6.0, 28.0, dist)));

		// Large lava outcrops. Low-frequency noise makes the shapes; slope only encourages them.
		// A slope gate by itself painted the whole gentle lip.
		float rock_blob = coast_fbm(world_xz * 0.016 + vec2(2.2, 6.4));
		float rock_mid = coast_fbm(world_xz * 0.055 + vec2(8.0, 1.5));
		float rock_w = smoothstep(0.42, 0.62, rock_blob + (rock_mid - 0.5) * 0.22);
		float rock_place = smoothstep(0.55, 1.4, height) * (1.0 - smoothstep(5.5, 12.0, height));
		rock_place *= 1.0 - smoothstep(6.0, 42.0, dist);
		rock_place = max(rock_place, smoothstep(0.12, 0.28, slope) * (1.0 - smoothstep(3.0, 28.0, dist)) * 0.85);
		rock_w *= rock_place;
		rock_w *= 1.0 - smoothstep(0.04, 0.4, cavity);
		rock_w = clamp(rock_w, 0.0, 1.0);
		sand_w = clamp(max(sand_w, cavity * (1.0 - smoothstep(8.0, 30.0, dist))), 0.0, 1.0);
		sand_w = clamp(sand_w * (1.0 - rock_w), 0.0, 1.0);

		// Grass tongues into the back of the sand, ahead of the painted vegetation line.
		float veg_w = smoothstep(sand_edge * 0.42, sand_edge * 0.95, dist);
		veg_w *= 1.0 - smoothstep(0.08, 0.32, slope);
		veg_w *= smoothstep(1.05, 2.2, height) * (1.0 - smoothstep(6.0, 15.0, height));
		veg_w *= smoothstep(0.46, 0.74, n_break);
		veg_w = clamp(veg_w * (1.0 - rock_w) * (1.0 - sand_w * 0.65), 0.0, 1.0);
		float paint_w = max(1.0 - sand_w - rock_w - veg_w, 0.0);
		float sumw = max(sand_w + rock_w + veg_w + paint_w, 0.001);
		sand_w /= sumw;
		rock_w /= sumw;
		veg_w /= sumw;
		paint_w /= sumw;

		vec2 ddx = base_ddx.xz;
		vec2 ddy = base_ddy.xz;
		vec3 sand_hi = coast_albedo(3, world_xz, ddx, ddy).rgb;
		vec3 sand_lo = coast_albedo(3, world_xz * 0.27 + vec2(37.0, -18.0), ddx, ddy).rgb;
		float macro = coast_fbm(world_xz * 0.018);
		float meso = coast_fbm(world_xz * 0.09 + vec2(4.0, 9.0));
		float grit = coast_noise(world_xz * 6.5);
		float specks = smoothstep(0.78, 0.93, coast_fbm(world_xz * 1.7 + vec2(1.0, 5.0)));
		vec3 sand_col = mix(sand_hi, sand_lo, 0.35 + 0.2 * macro);
		// Cool near-black, but the floor stays high enough that grain and ripples survive the sun.
		sand_col *= mix(vec3(0.78, 0.84, 0.98), vec3(1.08, 1.12, 1.22), meso);
		sand_col *= mix(0.84, 1.2, macro);
		sand_col *= mix(0.86, 1.16, grit);
		sand_col = mix(sand_col, sand_col * vec3(1.15, 1.2, 1.28) + vec3(0.008, 0.01, 0.016), specks * 0.28);

		vec3 rock_col = coast_albedo(0, world_xz, ddx, ddy).rgb;
		// Dark grey basalt, a step lighter and more neutral than the blue-black sand so the shelves read.
		rock_col = rock_col * vec3(0.72, 0.74, 0.78) + vec3(0.012, 0.013, 0.015);
		rock_col *= mix(0.75, 1.15, coast_fbm(world_xz * 0.03 + vec2(8.0, 1.0)));
		vec3 veg_col = coast_albedo(2, world_xz * 1.15, ddx, ddy).rgb;

		vec4 sand_nrm = coast_normal(3, world_xz, ddx, ddy);
		sand_nrm.xy = clamp((sand_nrm.xy - 0.5) * 0.55 + 0.5, 0.0, 1.0);
		vec4 rock_nrm = coast_normal(0, world_xz, ddx, ddy);
		rock_nrm.xy = clamp((rock_nrm.xy - 0.5) * 1.85 + 0.5, 0.0, 1.0);
		albedo = painted_albedo * paint_w + sand_col * sand_w + rock_col * rock_w + veg_col * veg_w;
		nrm = painted_normal * paint_w + sand_nrm.rgb * sand_w + rock_nrm.rgb * rock_w + painted_normal * veg_w;
		float rock_rough = max(rock_nrm.a, 0.92);
		rough = painted_rough * paint_w + sand_nrm.a * sand_w + rock_rough * rock_w + painted_rough * veg_w;
		spec = painted_spec * (paint_w + veg_w) + (1.0 - sand_nrm.a) * sand_w * 0.22 + (1.0 - rock_rough) * rock_w * 0.08;

		// Wave reach shares the ocean shader's phase so the sheen climbs and falls with the wash.
		float wave_a = dot(world_xz, vec2(0.063, 0.079)) - TIME * 0.96;
		float wave_b = dot(world_xz, vec2(-0.091, 0.041)) - TIME * 1.14;
		float phase = TIME * 0.92 + 0.37 * sin(dot(world_xz, vec2(0.027, 0.016))) + 0.26 * sin(wave_b);
		float tide = sin(phase);
		// Wet sand is darker than the dry beach and glossy. The upper edge is a soft, wandering
		// falloff, not a height contour. Normals stay grainy so the sky reflection sparkles
		// instead of forming a pale stripe.
		float wet_n = coast_fbm(world_xz * 0.22 + vec2(3.0, 9.0));
		float reach = 0.12 + 0.62 * max(tide, 0.0) + 0.1 * sin(wave_a);
		reach += (wet_n - 0.5) * 0.55;
		float wet = 1.0 - smoothstep(reach, reach + 0.55, height);
		float trail = (1.0 - smoothstep(-0.2, 0.7, tide)) * (1.0 - smoothstep(reach, reach + 0.7, height));
		wet = max(wet, trail * 0.55);
		wet *= smoothstep(-0.15, 0.05, height) * max(sand_w, rock_w * 0.35);
		wet = clamp(wet, 0.0, 1.0);

		albedo = mix(albedo, albedo * vec3(0.22, 0.25, 0.32), wet);
		// Soft sheen on the whole swash. Glints are a sun/view spike on tiny grains, not white blobs.
		rough = mix(rough, 0.7, wet * (1.0 - rock_w));
		rough = mix(rough, 0.48, wet * rock_w);
		spec = mix(spec, 0.28, wet);
		vec3 n_view = normalize(mat3(TANGENT, BINORMAL, NORMAL) * (nrm * 2.0 - 1.0));
		vec3 sun_dir = normalize(vec3(-0.55, 0.74, 0.37));
		vec3 sun_view = normalize((VIEW_MATRIX * vec4(sun_dir, 0.0)).xyz);
		vec3 half_dir = normalize(sun_view + normalize(-VERTEX));
		float micro = coast_noise(world_xz * 55.0);
		float glint = pow(clamp(dot(n_view, half_dir), 0.0, 1.0), 96.0);
		glint *= smoothstep(0.62, 0.9, micro) * wet;
		albedo += vec3(0.16, 0.18, 0.2) * glint;

		// A thin lace only, right against the water. It must not paint the whole bank.
		float lace = coast_fbm(world_xz * 0.55 + vec2(TIME * 0.08, wet_n * 2.0));
		float sheets = exp(-height * height * 40.0) * smoothstep(0.55, 0.85, lace);
		sheets *= (0.35 + 0.65 * max(tide, 0.0));
		sheets = clamp(sheets, 0.0, 0.22);
		albedo = mix(albedo, vec3(0.8, 0.84, 0.82), sheets);
		rough = mix(rough, 0.62, sheets);
		spec = mix(spec, 0.18, sheets);

	}
	// Distant foliage reads as a canopy even where plant cards are subpixel.
	float scenic_distance = length(CAMERA_POSITION_WORLD - v_vertex);
	float canopy = smoothstep(5.5, 17.0, height) * (1.0 - smoothstep(125.0, 191.0, height));
	canopy *= 1.0 - smoothstep(0.13, 0.27, slope);
	float lava = smoothstep(220.0, 480.0, world_xz.x) * smoothstep(-160.0, 40.0, world_xz.y);
	canopy *= 1.0 - lava;
	if (canopy > 0.0) {
		float grove = coast_fbm(world_xz * 0.065);
		float crowns = coast_noise(world_xz * 0.26);
		float cover = canopy * smoothstep(0.21, 0.60, grove);
		float range_mix = mix(0.38, 0.90, smoothstep(65.0, 380.0, scenic_distance));
		vec3 forest = mix(vec3(0.040, 0.089, 0.030), vec3(0.126, 0.239, 0.077), crowns);
		albedo = mix(albedo, forest, cover * range_mix);
		rough = mix(rough, 0.91, cover * range_mix);
	}
	// Recover warm minerals in the basalt while keeping the wet black sand dark.
	float green = smoothstep(0.014, 0.14, albedo.g - 0.5 * (albedo.r + albedo.b));
	float coast_grade = 1.0 - smoothstep(5.0, 28.0, height);
	vec3 mineral = albedo * mix(vec3(1.09, 1.03, 0.95), vec3(1.13, 1.05, 0.95), coast_grade);
	mineral += vec3(0.007, 0.004, 0.002) * smoothstep(0.4, 15.0, height);
	float luminance = dot(albedo, vec3(0.213, 0.715, 0.072));
	vec3 mineral_target = mix(volcanic_charcoal.rgb, volcanic_earth.rgb,
		smoothstep(0.08, 0.38, luminance) * smoothstep(-0.024, 0.092, albedo.r - albedo.b));
	mineral_target *= clamp(luminance / max(dot(mineral_target, vec3(0.213, 0.715, 0.072)), 0.045), 0.32, 1.55);
	mineral = mix(mineral, mineral_target, 0.28 * (1.0 - coast_grade * 0.64));
	vec3 tropical = albedo * vec3(0.94, 1.13, 1.07);
	// Apply PBR
	vec2 deposit_uv = (v_vertex.xz + vec2(1152.0)) / 2304.0;
	float ash = texture(volcanic_deposit, deposit_uv).r;
	ALBEDO = mix(mix(mineral, tropical, green), vec3(.19,.165,.145),
		ash * .70 * smoothstep(.65,2.0,v_vertex.y));
	float summit = 1.0 - smoothstep(14.0,57.0,length(v_vertex-vec3(48.0,358.51,-126.0)));
	float field = 1.0 - smoothstep(17.0,73.0,length((v_vertex.xz-vec2(534.0,106.0))/vec2(1.45,1.0)));
	float cracks = pow(1.0-abs(sin(v_vertex.x*.32+v_vertex.z*.23+sin(v_vertex.z*.47)*1.9)), 14.0);
	EMISSION = vec3(1.0,.18,.026) * volcanic_glow * cracks
		* max(summit, field * (1.0 - green) * smoothstep(15.0,55.0,v_vertex.y))
		* (.47+.25*sin(TIME*1.6+v_vertex.z*.14));
	ROUGHNESS = clamp(rough, 0.0, 1.0);
	SPECULAR = clamp(spec, 0.0, 1.0);
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = mat.normal_map_depth;
	AO = clamp(mat.ao, 0., 1.);
	AO_LIGHT_AFFECT = mat.ao_affect;


}

