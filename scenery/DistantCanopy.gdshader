shader_type spatial;
render_mode shadows_disabled;

uniform float canopy_start = 205.0;
uniform float canopy_span = 100.0;
varying float fade;
varying float leaf_height;

void vertex() {
	leaf_height = VERTEX.y;
	fade = smoothstep(canopy_start, canopy_start + canopy_span, distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD));
}

void fragment() {
	float threshold = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (fade <= 1.0 - threshold) {
		discard;
	}
	vec3 canopy_green = COLOR.rgb * vec3(0.91, 1.12, 1.13) + vec3(0.003, 0.009, 0.004);
	vec3 leaves = canopy_green * mix(0.66, 1.23, smoothstep(0.37, 1.0, leaf_height));
	ALBEDO = mix(vec3(0.096, 0.071, 0.042), leaves, smoothstep(0.34, 0.43, leaf_height));
	ROUGHNESS = 0.95;
	SPECULAR = 0.08;
}
