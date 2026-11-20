shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform vec4 roofs[64];
uniform int roof_count = 0;
uniform float ground_y;
varying vec3 world;
void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
}
void fragment() {
	if (world.y < ground_y) { discard; }
	for (int i = 0; i < roof_count; i++) {
		vec3 offset = world - roofs[i].xyz;
		float c = cos(roofs[i].w), s = sin(roofs[i].w);
		vec2 local = abs(vec2(c*offset.x-s*offset.z,s*offset.x+c*offset.z));
		if (offset.y < 0.0 && max(local.x,local.y) < 2.1) { discard; }
	}
	ALBEDO = vec3(.65,.76,.80);
	ALPHA = .33;
}
