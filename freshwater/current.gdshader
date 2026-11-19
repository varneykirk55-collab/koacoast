shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, shadows_disabled;

varying vec4 channel;
varying vec2 world_xz;

void vertex() {
	channel = COLOR;
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float cross_flow = UV.x;
	float travel = UV.y;
	float speed = mix(1.15, 7.0, channel.g);
	float t = travel - TIME * speed;
	float riffles = sin(t * 5.6 + sin(cross_flow * 20.0 + travel * 0.6));
	float threads = sin(cross_flow * 73.0 + sin(t * 0.8) * 0.8);
	float ripples = sin(t * 2.2 + cross_flow * 11.0);
	float slope_foam = smoothstep(0.4, 0.93, riffles * 0.43 + threads * 0.35 + ripples * 0.22);
	float impact = channel.b * smoothstep(-0.25, 0.75, riffles * 0.55 + threads * 0.45);
	float foam = max(slope_foam * channel.g, impact);
	float depth = channel.r;
	vec3 shallows = vec3(0.07, 0.34, 0.27);
	vec3 deep = vec3(0.014, 0.19, 0.19);
	vec3 water = mix(shallows, deep, depth);
	float bank = smoothstep(0.05, 0.32, depth);
	float grain = sin(world_xz.x * 4.3) * sin(world_xz.y * 5.1);
	water = mix(vec3(0.10, 0.14, 0.108) + grain * 0.022, water, bank);
	water += riffles * 0.013 + ripples * 0.012;
	water = mix(water, vec3(0.045, 0.33, 0.37), channel.a * 0.78);
	ALBEDO = mix(water, vec3(0.74, 0.88, 0.86), foam);
	ROUGHNESS = mix(0.22, 0.61, foam);
	SPECULAR = mix(0.53, 0.19, foam);
}
