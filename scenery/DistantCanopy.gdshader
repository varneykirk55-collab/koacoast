shader_type spatial;
render_mode shadows_disabled;

uniform float canopy_start = 205.0;
varying float fade;

void vertex() {
	fade = smoothstep(canopy_start, canopy_start + 100.0, distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD));
}

void fragment() {
	float threshold = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (fade <= threshold) {
		discard;
	}
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.95;
	SPECULAR = 0.08;
}
