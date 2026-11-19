shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, skip_vertex_transform;

varying float life;

void vertex() {
	float seed = COLOR.r;
	life = fract(TIME * (0.45 + seed * 0.25) + seed);
	float angle = seed * 91.7;
	float spread = COLOR.g * (0.25 + life);
	vec3 drift = vec3(cos(angle) * spread, (0.18 + life) * COLOR.g, sin(angle) * spread);
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX + drift, 1.0)).xyz;
	VERTEX.xy += (UV - vec2(0.5)) * COLOR.g * (0.65 + life * 1.5);
}

void fragment() {
	float falloff = 1.0 - smoothstep(0.05, 0.5, length(UV - vec2(0.5)));
	ALBEDO = vec3(0.78, 0.91, 0.91);
	ALPHA = falloff * sin(life * PI) * 0.19;
}
