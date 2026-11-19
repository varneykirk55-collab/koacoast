shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, skip_vertex_transform;

uniform float spray_range = 170.0;
varying float life;
varying float fade;
varying float seed;

void vertex() {
	seed = UV2.x;
	float radius = UV2.y;
	life = fract(TIME * mix(0.30, 0.72, seed) + seed);
	float angle = seed * 91.7;
	float spread = radius * (0.18 + life) * mix(0.58, 1.5, seed);
	vec3 drift = vec3(cos(angle) * spread, radius * (0.20 + sin(life * 2.3) * 0.85), sin(angle) * spread);
	fade = 1.0 - smoothstep(spray_range * 0.65, spray_range, distance(CAMERA_POSITION_WORLD, VERTEX));
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX + drift, 1.0)).xyz;
	VERTEX.xy += (UV - vec2(0.5)) * radius * mix(1.0, 3.3, life) * fade;
}

void fragment() {
	vec2 uv = UV - vec2(0.5);
	float wobble = sin(uv.x * 9.0 + seed * 18.0) * cos(uv.y * 7.0 - seed * 9.0) * 0.028;
	float falloff = 1.0 - smoothstep(0.0, 0.50, length(uv * vec2(1.0, 0.9)) + wobble);
	ALBEDO = mix(vec3(0.67, 0.76, 0.77), vec3(0.91, 0.93, 0.91), seed);
	ALPHA = falloff * sin(life * PI) * 0.20 * fade;
}
