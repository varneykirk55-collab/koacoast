shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, shadows_disabled;

uniform sampler2D flow_detail : repeat_enable, filter_linear_mipmap;
uniform float detail_range = 175.0;
varying vec4 channel;
varying float camera_range;
varying float distance_blend;
varying float pool;

void vertex() {
	channel = COLOR;
	camera_range = distance(CAMERA_POSITION_WORLD, (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	distance_blend = smoothstep(105.0, 310.0, camera_range);
	VERTEX += CUSTOM0.xyz * distance_blend;
	pool = CUSTOM0.w;
}

void fragment() {
	float across = UV.x;
	float along = UV.y;
	float fall = UV2.x;
	float width = max(0.25, UV2.y);
	float edge = min(across, 1.0 - across);
	float core = smoothstep(0.015, 0.27, edge);
	float depth = max(channel.r, pool * core * 0.78);

	// A distant surface keeps the same color family and silhouette at every preset.
	vec3 far_color = mix(vec3(0.084, 0.235, 0.228), vec3(0.105, 0.320, 0.314), depth);
	far_color = mix(far_color, vec3(0.088, 0.315, 0.36), channel.a * 0.45);
	float far_foam = max(smoothstep(0.07, 0.78, fall) * mix(0.43, 0.87, core), channel.b * core * 0.55);
	far_color = mix(far_color, vec3(0.68, 0.75, 0.74), far_foam);
	vec3 water = far_color;
	float foam = far_foam;

	if (distance_blend < 0.999) {
		float motion = mix(0.55, 7.2, max(fall, channel.g * 0.42));
		float t = along - TIME * motion;
		float fade = (1.0 - distance_blend) * (1.0 - smoothstep(detail_range * 0.62, detail_range, camera_range));
		float broad = sin(t * mix(0.68, 1.35, fall) + across * 3.6);
		float feather = 0.5;
		if (fade > 0.0) {
			feather = texture(flow_detail, vec2(across * width * 0.21, t * 0.075)).g;
		}
		float moving_water = mix(0.5, 0.5 + broad * 0.18, fade);
		float trough = sin(across * (9.0 + width * 2.6) + 0.38 * sin(t * 0.44));
		float strands = mix(0.5, 0.5 + trough * 0.27 + (feather - 0.5) * 0.28, fade);
		// Foam rides the center of rapids and spreads at the foot of the drop.
		float rapid = channel.g * (1.0 - pool * 0.55) * smoothstep(0.31, 0.76, moving_water) * core;
		float plunge = channel.b * smoothstep(0.21, 0.73, moving_water + core * 0.26);
		float whitewater = fall * mix(0.34, 0.88, smoothstep(0.13, 0.83, strands)) * mix(0.66, 1.0, core);
		foam = clamp(max(whitewater, rapid * (1.0 - fall * 0.7)) + plunge * 0.58, 0.0, 0.96);

		// Approximate light transmitted from the bed with depth and edge color.
		// The shared opaque pass keeps crossings and the ocean mouth depth-sorted.
		vec3 shallows = vec3(0.125, 0.263, 0.195);
		vec3 deep = mix(vec3(0.045, 0.156, 0.158), vec3(0.052, 0.239, 0.226), pool);
		vec3 near_color = mix(shallows, deep, smoothstep(0.03, 0.90, depth));
		near_color = mix(near_color, vec3(0.073, 0.275, 0.31), channel.a * 0.54);
		float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
		float fresnel = pow(1.0 - facing, 4.0);
		near_color = mix(near_color, vec3(0.30, 0.44, 0.49), fresnel * (0.23 + 0.12 * pool));
		near_color += (moving_water - 0.50) * 0.08;
		vec3 veil = mix(vec3(0.26, 0.39, 0.40), vec3(0.70, 0.76, 0.75), strands);
		near_color = mix(near_color, veil, fall * 0.60);
		near_color = mix(near_color, vec3(0.78, 0.82, 0.80), foam);
		water = mix(near_color, far_color, distance_blend);
		foam = mix(foam, far_foam, distance_blend);
	}

	ALBEDO = water;
	EMISSION = far_color * distance_blend * 0.095;
	ROUGHNESS = mix(mix(0.24, 0.39, pool), 0.69, foam);
	SPECULAR = mix(0.34, 0.08, max(foam, distance_blend));
}
