shader_type spatial;
render_mode cull_disabled;
uniform sampler2D foliage_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
varying vec3 leaf_normal;
varying float upper_light;
void vertex() {
    // Vary crown lean and the spread of each clump while keeping its planted origin.
    vec2 origin = MODEL_MATRIX[3].xz;
    vec2 key = fract(sin(vec2(dot(origin, vec2(.0821,.0287)), dot(origin, vec2(.0237,.0683)))) * 4597.17);
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
    vec4 texel = texture(foliage_atlas, UV);
    ALBEDO = texel.rgb * COLOR.rgb * upper_light;
    ALPHA = texel.a;
    ALPHA_SCISSOR_THRESHOLD = .30;
    NORMAL = normalize(leaf_normal);
    ROUGHNESS = .85;
    SPECULAR = .20;
}
