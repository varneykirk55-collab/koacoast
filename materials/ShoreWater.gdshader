shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D coastal_shelf : filter_linear_mipmap, repeat_disable;
uniform sampler2D ocean_detail : filter_linear_mipmap, repeat_enable;
uniform vec4 deep : source_color = vec4(0.018, 0.125, 0.265, 1.0);
uniform vec4 shelf_blue : source_color = vec4(0.012, 0.29, 0.42, 1.0);
uniform vec4 lagoon : source_color = vec4(0.075, 0.48, 0.43, 1.0);
uniform vec4 breaker : source_color = vec4(0.90, 0.96, 0.92, 1.0);
varying vec3 surface_world;

// CoastalShelf encodes -48 to +16 metres. Texel centres match the terrain.
// A higher mip plus a wide offset kills the 2 m shelf squares in the shallows.
float shelf_smooth(vec2 p) {
    vec2 uv = (p + 1025.0) / 2048.0;
    float lod = 2.5;
    vec2 o = vec2(0.012, 0.0);
    vec2 q = vec2(0.0, 0.012);
    float h = textureLod(coastal_shelf, uv, lod).r * 4.0;
    h += textureLod(coastal_shelf, uv + o, lod).r;
    h += textureLod(coastal_shelf, uv - o, lod).r;
    h += textureLod(coastal_shelf, uv + q, lod).r;
    h += textureLod(coastal_shelf, uv - q, lod).r;
    return h * 0.125 * 64.0 - 48.0;
}
float shelf_raw(vec2 p) {
    return textureLod(coastal_shelf, (p + 1025.0) / 2048.0, 0.0).r * 64.0 - 48.0;
}
float shelf_depth(vec2 p) {
    return max(0.0,-shelf_raw(p));
}
void vertex() {
    vec2 p = (MODEL_MATRIX * vec4(VERTEX,1.0)).xz;
    float depth = shelf_depth(p);
    float fade = (1.0-smoothstep(1230.0,1800.0,max(abs(p.x),abs(p.y))))*smoothstep(0.0,2.2,depth);
    float a = dot(p,vec2(.063,.079))-TIME*.96;
    float b = dot(p,vec2(-.091,.041))-TIME*1.14;
    VERTEX.y += fade*(.23*sin(a)+.11*sin(b));
    surface_world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
}
void fragment() {
    vec2 p=surface_world.xz;
    float depth=max(0.0,-shelf_smooth(p));
    float range_m=length(CAMERA_POSITION_WORLD-surface_world);
    float a=dot(p,vec2(.063,.079))-TIME*.96;
    float b=dot(p,vec2(-.091,.041))-TIME*1.14;
    vec2 swell=.23*vec2(.063,.079)*cos(a)+.11*vec2(-.091,.041)*cos(b);
    vec3 wind=texture(ocean_detail,p/37.0+TIME*vec2(.008,-.005)).rgb;
    vec2 capillary=texture(ocean_detail,vec2(p.y,-p.x)/12.5+TIME*vec2(.012,.008)).rg-.5;
    swell*= (1.0-smoothstep(650.0,3500.0,range_m)) / (1.0+fwidth(a)+fwidth(b));
    vec2 tilt=swell+(wind.rg-.5)*.44+capillary*.24*(1.0-smoothstep(120.0,850.0,range_m));
    tilt*=1.0-smoothstep(1900.0,6500.0,range_m);
    vec3 world_n=normalize(vec3(-tilt.x,1.0,-tilt.y));
    NORMAL=normalize(mat3(VIEW_MATRIX)*world_n);
    float grazing=pow(1.0-clamp(dot(normalize(CAMERA_POSITION_WORLD-surface_world),world_n),0.0,1.0),4.0);
    vec3 water=mix(deep.rgb,shelf_blue.rgb,exp(-depth*.080));
    water=mix(water,lagoon.rgb,exp(-depth*.165));
    // Original swash and crest, kept bright, plus a break that is strongest just off the sand
    // and thins as it reaches the beach. The terrain shader draws the wash that runs up the sand.
    float phase=TIME*.92+.37*sin(dot(p,vec2(.027,.016)))+.26*sin(b);
    float lace=texture(ocean_detail,p/27.0+tilt*.22+TIME*vec2(-.004,.007)).b;
    float lip_n=texture(ocean_detail,p/11.0+TIME*vec2(.02,-.015)).g;
    float wash_edge=1.00+.64*sin(phase)+.22*sin(a);
    float swash=(1.0-smoothstep(.08,1.65,abs(depth-wash_edge)))*mix(.55,1.0,lace);
    float front=4.45-1.28*sin(phase-.9)+.40*cos(a*.72);
    float crest=(1.0-smoothstep(.12,1.24,abs(depth-front)))*smoothstep(.15,.75,.61*lace+.39*wind.b);
    float break_d=.45+.85*(.5+.5*sin(phase));
    float breaker_line=exp(-abs(depth-break_d)*1.7)*mix(.65,1.0,lace);
    // Don't lay a solid white knife-edge exactly on the sand.
    float off_sand=smoothstep(0.05,0.55,depth);
    float foam=clamp((swash*.97+crest*.75+breaker_line*.8)*mix(.25,1.0,off_sand),0.0,1.0);
    ALBEDO=mix(water,breaker.rgb,foam);
    ROUGHNESS=mix(.19+.055*wind.b,.83,foam);
    SPECULAR=mix(.49,.12,foam);
    float edge=smoothstep(0.0,.7,depth+(lip_n-.5)*.2);
    // Slightly milkier shallows hide the 2 m seabed grid without covering the sand.
    float opacity=mix(.64,.995,1.0-exp(-depth*.4));
    opacity*=mix(.6,1.0,edge);
    ALPHA=mix(opacity,1.0,max(foam,grazing*.78*smoothstep(.25,1.2,depth)));
}
