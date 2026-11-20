shader_type spatial;
render_mode cull_disabled;
uniform float head;
uniform float length;
void fragment() {
	float trail = head - UV.y;
	if (trail < 0.0 || trail > length) { discard; }
	float swirl = sin(UV.x*23.0 + UV.y*.66 - TIME*4.6)
		* sin(UV.y*2.2 - TIME*13.0 + UV.x*8.0);
	float front = 1.0 - smoothstep(0.0, 3.0, trail);
	ALBEDO = mix(vec3(.10,.05,.026), vec3(.30,.18,.09), clamp(.45+swirl*.33+front*.23,0.0,1.0));
	ROUGHNESS = .48;
}
