shader_type spatial;
render_mode cull_disabled;
uniform sampler2D foliage_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float detail_range = 65000.0;
uniform float fade_span = 50.0;
varying float detail_fade;
varying vec3 leaf_normal;
varying float upper_light;
varying float green_variation;
void vertex() {
    // Vary crown lean and the spread of each clump while keeping its planted origin.
    detail_fade = 1.0 - smoothstep(detail_range - fade_span, detail_range, distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD));
    vec2 origin = MODEL_MATRIX[3].xz;
    vec2 key = fract(sin(vec2(dot(origin, vec2(.0821,.0287)), dot(origin, vec2(.0237,.0683)))) * 4597.17);
    green_variation = key.y;
    float h = max(0.,VERTEX.y);
    float phase = (key.x-.5)*.40 * smoothstep(.02,1.4,h);
    mat2 r = mat2(vec2(cos(phase),sin(phase)),vec2(-sin(phase),cos(phase)));
    VERTEX.xz = r * VERTEX.xz;
    NORMAL.xz = r * NORMAL.xz;
    VERTEX.xz *= .86+.30*key.y;
    VERTEX.xz += (key-.5)*h*(.10+.035*h);
    leaf_normal = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
    upper_light = .82+.18*smoothstep(.03,1.15,h);
}
void fragment() {
    float threshold = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
    if (detail_fade <= threshold) {
        discard;
    }
    vec4 texel = texture(foliage_atlas, UV);
    vec3 base = texel.rgb * COLOR.rgb;
    float leaf = smoothstep(0.018, 0.16, base.g - 0.5 * (base.r + base.b));
    vec3 tint = mix(vec3(0.88, 1.05, 1.18), vec3(1.01, 1.09, 1.08), green_variation);
    vec3 green = base * tint + vec3(0.003, 0.008, 0.006);
    ALBEDO = mix(base, green, leaf) * upper_light;
    ALPHA = texel.a;
    ALPHA_SCISSOR_THRESHOLD = .30;
    NORMAL = normalize(leaf_normal);
    ROUGHNESS = .85;
    SPECULAR = .20;
}
