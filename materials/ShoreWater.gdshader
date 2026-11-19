shader_type spatial;
// The baked grid faces down. The shader supplies an upward surface normal.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

uniform sampler2D coastal_shelf : filter_linear_mipmap, repeat_disable;
uniform sampler2D ocean_detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 deep : source_color = vec4(0.012, 0.08, 0.2, 1.0);
uniform vec4 shelf_blue : source_color = vec4(0.01, 0.32, 0.42, 1.0);
uniform vec4 lagoon : source_color = vec4(0.05, 0.62, 0.55, 1.0);
uniform vec4 breaker : source_color = vec4(0.95, 0.98, 0.96, 1.0);
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
    float warp = texture(ocean_detail, p / 18.0).g - 0.5;
    float depth = max(0.0, -shelf_h(p, 2.2) - warp * 0.8);
    float range_m = length(CAMERA_POSITION_WORLD - surface_world);
    float a = dot(p, vec2(0.063, 0.079)) - TIME * 0.96;
    float b = dot(p, vec2(-0.091, 0.041)) - TIME * 1.14;
    vec2 swell = 0.28 * vec2(0.063, 0.079) * cos(a) + 0.14 * vec2(-0.091, 0.041) * cos(b);
    vec2 fine = texture(ocean_detail, p / 9.0 + TIME * vec2(0.04, -0.02)).rg - 0.5;
    vec2 finer = texture(ocean_detail, vec2(p.y, -p.x) / 3.2 + TIME * vec2(-0.06, 0.04)).rg - 0.5;
    float chop = 1.0 - smoothstep(80.0, 900.0, range_m);
    swell *= (1.0 - smoothstep(650.0, 3500.0, range_m)) / (1.0 + fwidth(a) + fwidth(b));
    vec2 tilt = swell + fine * mix(0.35, 0.85, chop) + finer * 0.45 * chop;
    tilt *= 1.0 - smoothstep(1900.0, 6500.0, range_m);
    vec3 world_n = normalize(vec3(-tilt.x, 1.0, -tilt.y));
    NORMAL = normalize(mat3(VIEW_MATRIX) * world_n);

    vec3 view = normalize(CAMERA_POSITION_WORLD - surface_world);
    float ndotv = clamp(dot(world_n, view), 0.0, 1.0);
    float fres = pow(1.0 - ndotv, 4.0);
    vec3 water = mix(deep.rgb, shelf_blue.rgb, exp(-depth * 0.08));
    water = mix(water, lagoon.rgb, exp(-depth * 0.18));
    if (depth < 12.0) {
        vec3 bed = texture(screen_tex, SCREEN_UV + tilt * 0.01 * exp(-depth * 0.5)).rgb;
        water = mix(water, bed * vec3(0.4, 0.75, 0.7), exp(-depth * 0.7) * 0.35 * (1.0 - smoothstep(8.0, 12.0, depth)));
    }
    vec3 sky = mix(vec3(0.4, 0.58, 0.76), vec3(0.75, 0.86, 0.94), clamp(world_n.y, 0.0, 1.0));
    water = mix(water, sky, fres * 0.22);
    water += lagoon.rgb * clamp(sin(a) * 0.5 + 0.5, 0.0, 1.0) * ndotv * 0.08;
    float spec = pow(clamp(dot(world_n, normalize(normalize(sun_dir) + view)), 0.0, 1.0), 90.0);
    water += vec3(1.0, 0.96, 0.88) * spec * 0.45;

    float foam = 0.0;
    if (depth < 16.0) {
        float phase = TIME * 0.92 + 0.37 * sin(dot(p, vec2(0.027, 0.016))) + 0.26 * sin(b);
        float lace = texture(ocean_detail, p / 27.0 + tilt * 0.22 + TIME * vec2(-0.004, 0.007)).b;
        float lip = texture(ocean_detail, p / 11.0 + TIME * vec2(0.02, -0.015)).g;
        float wash_edge = 1.0 + 0.64 * sin(phase) + 0.22 * sin(a) + warp * 0.6;
        float swash = (1.0 - smoothstep(0.08, 1.65, abs(depth - wash_edge))) * mix(0.55, 1.0, lace);
        float front = 4.45 - 1.28 * sin(phase - 0.9) + 0.4 * cos(a * 0.72);
        float crest = (1.0 - smoothstep(0.12, 1.24, abs(depth - front))) * smoothstep(0.15, 0.75, 0.61 * lace + 0.39 * lip);
        float break_d = 0.45 + 0.85 * (0.5 + 0.5 * sin(phase));
        float line = exp(-abs(depth - break_d) * 1.7) * mix(0.65, 1.0, lace);
        float off_sand = smoothstep(0.0, 0.55, depth + warp * 0.4);
        foam = clamp((swash * 0.97 + crest * 0.75 + line * 0.8) * mix(0.35, 1.0, off_sand), 0.0, 1.0);
        water = mix(water, breaker.rgb, foam);

    }

    float edge = smoothstep(0.0, 0.9, depth + warp * 0.55);
    float alpha = mix(0.62, 0.99, 1.0 - exp(-depth * 0.4));
    alpha *= mix(0.72, 1.0, edge);
    alpha = mix(alpha, 1.0, max(foam, fres * 0.5 * smoothstep(0.25, 1.2, depth)));
    ALBEDO = water;
    ROUGHNESS = mix(0.14, 0.8, foam);
    SPECULAR = mix(0.5, 0.12, foam);
    ALPHA = clamp(alpha, 0.0, 1.0);
}
