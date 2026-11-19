shader_type spatial;
// The baked grid faces down. The shader supplies an upward surface normal.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

uniform sampler2D coastal_shelf : filter_linear_mipmap, repeat_disable;
uniform sampler2D ocean_detail : filter_linear_mipmap, repeat_enable;
uniform vec4 deep : source_color = vec4(0.043137, 0.333333, 0.572549, 1.0);
uniform vec4 shelf_blue : source_color = vec4(0.028, 0.47, 0.61, 1.0);
uniform vec4 lagoon : source_color = vec4(0.145098, 0.725490, 0.764706, 1.0);
uniform vec4 breaker : source_color = vec4(0.89, 0.95, 0.94, 1.0);
uniform vec3 sun_dir = vec3(-0.55, 0.74, 0.37);

varying vec3 surface_world;

float shelf_h(vec2 p, float lod) {
    vec2 uv = (p + 1025.0) / 2048.0;
    return textureLod(coastal_shelf, uv, lod).r * 64.0 - 48.0;
}

void vertex() {
    vec2 p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
    float depth = max(0.0, -shelf_h(p, 1.0));
    float fade = (1.0 - smoothstep(1230.0, 1800.0, max(abs(p.x), abs(p.y)))) * smoothstep(0.0, 2.2, depth);
    float a = dot(p, vec2(0.063, 0.079)) - TIME * 0.96;
    float b = dot(p, vec2(-0.091, 0.041)) - TIME * 1.14;
    VERTEX.y += fade * (0.28 * sin(a) + 0.14 * sin(b));
    surface_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    vec2 p = surface_world.xz;
    float depth = max(0.0, -shelf_h(p, 2.2));
    float range_m = length(CAMERA_POSITION_WORLD - surface_world);
    float a = dot(p, vec2(0.063, 0.079)) - TIME * 0.96;
    float b = dot(p, vec2(-0.091, 0.041)) - TIME * 1.14;
    float ruffle = dot(p, vec2(0.29, -0.16)) - TIME * 1.45;
    // Preserve readable swell at the shore and suppress repeating normals
    // across the large offshore footprint seen from the summit.
    float wave_fade = 1.0 - smoothstep(110.0, 1250.0, range_m);
    wave_fade *= mix(1.0, 0.36, smoothstep(100.0, 440.0, range_m));
    vec2 tilt = (
        vec2(0.027, 0.039) * cos(a) / (1.0 + fwidth(a))
        + vec2(-0.032, 0.017) * cos(b) / (1.0 + fwidth(b))
        + vec2(0.012, -0.011) * cos(ruffle) / (1.0 + fwidth(ruffle))
    ) * wave_fade;
    vec3 world_n = normalize(vec3(-tilt.x, 1.0, -tilt.y));
    NORMAL = normalize(mat3(VIEW_MATRIX) * world_n);

    vec3 view = normalize(CAMERA_POSITION_WORLD - surface_world);
    float facing = max(dot(world_n, view), 0.0);
    float fresnel = 0.022 + 0.82 * pow(1.0 - facing, 5.0);
    vec3 reflected = reflect(-view, world_n);
    vec3 sky = mix(vec3(0.24, 0.39, 0.49), vec3(0.20, 0.42, 0.65),
        smoothstep(-0.03, 0.72, reflected.y));
    vec3 water = mix(deep.rgb, shelf_blue.rgb, exp(-depth * 0.077));
    water = mix(water, lagoon.rgb, exp(-depth * 0.22));
    water = mix(water, sky, fresnel * 0.56);
    float sun = max(dot(reflected, normalize(sun_dir)), 0.0);
    water += vec3(1.0, 0.91, 0.75) * pow(sun, 72.0) * 0.24 * wave_fade;

    float foam = 0.0;
    if (depth < 14.0) {
        // Keep the coastal swash in phase with the wet sand beneath it.
        float phase = TIME * 0.92 + 0.37 * sin(dot(p, vec2(0.027, 0.016))) + 0.26 * sin(b);
        float lace = texture(ocean_detail, p / 33.0 + TIME * vec2(-0.004, 0.007)).b;
        float shore = 0.77 + sin(phase) * 0.56 + cos(a) * 0.16;
        float crest = 4.10 - sin(phase - 0.9) * 1.07 + 0.32 * cos(a * 0.72);
        float band = clamp(fwidth(depth), 0.10, 0.85);
        float swash = 1.0 - smoothstep(0.12, 0.82 + band, abs(depth - shore));
        float breaker_wave = 1.0 - smoothstep(0.12, 0.98 + band, abs(depth - crest));
        foam = clamp((swash * 0.78 + breaker_wave * smoothstep(0.28, 0.70, lace) * 0.69)
            * smoothstep(0.0, 0.47, depth), 0.0, 0.92);
    }

    float alpha = mix(0.45, 0.99, 1.0 - exp(-depth * 0.30));
    alpha = mix(alpha, 1.0, max(foam, fresnel * smoothstep(0.10, 1.6, depth) * 0.65));
    ALBEDO = mix(water, breaker.rgb, foam);
    ROUGHNESS = mix(0.21, 0.72, foam);
    SPECULAR = mix(0.29, 0.10, foam);
    // Blend into the sky before the ocean grid reaches its outer perimeter.
    ALPHA = alpha * (1.0 - smoothstep(19000.0, 45000.0, range_m));
}
