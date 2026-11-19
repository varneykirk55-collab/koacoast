shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, shadows_disabled;

uniform sampler2D flow_detail : repeat_enable, filter_linear_mipmap;
uniform float detail_range = 175.0;
varying vec4 channel;
varying float camera_range;

void vertex() {
	channel = COLOR;
	camera_range = distance(CAMERA_POSITION_WORLD, (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	float across = UV.x;
	float travel = UV.y;
	float fall = UV2.x;
	float width = max(0.25, UV2.y);
	float strength = max(fall, channel.g * 0.42);
	float t = travel - TIME * mix(0.75, 8.5, strength);
	float fade_detail = 1.0 - smoothstep(detail_range * 0.65, detail_range, camera_range);
	vec3 streak = texture(flow_detail, vec2(across * width * 0.36, t * 0.085)).rgb;
	float curls = streak.g;
	if (fade_detail > 0.0) {
		curls = mix(curls, texture(flow_detail, vec2(across * width * 0.83 + streak.b * 0.16, t * 0.24)).b, 0.55 * fade_detail);
	}
	float edge = min(across, 1.0 - across);
	float core = smoothstep(0.015 + streak.r * 0.045, 0.21, edge);
	float whitewater = strength * smoothstep(0.23, 0.74, curls + fall * 0.23);
	float falling_sheet = fall * mix(0.55, 1.0, core) * mix(0.48, 0.88, streak.r);
	float impact = channel.b * smoothstep(0.17, 0.70, 0.65 * curls + 0.4 * core);
	float foam = clamp(max(whitewater, falling_sheet) + impact * 0.68, 0.0, 1.0);

	vec3 stone_water = vec3(0.082, 0.12, 0.106);
	vec3 deep = vec3(0.035, 0.14, 0.13);
	vec3 water = mix(stone_water, deep, smoothstep(0.03, 0.79, channel.r));
	water = mix(water, vec3(0.075, 0.205, 0.218), channel.a * 0.6);
	water += (curls - 0.5) * 0.065;
	ALBEDO = mix(water, vec3(0.81, 0.86, 0.84), foam * mix(core, 1.0, fall));
	ROUGHNESS = mix(0.19, 0.73, foam);
	SPECULAR = mix(0.51, 0.16, foam);
}
