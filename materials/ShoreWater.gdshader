shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D coastal_shelf : filter_linear, repeat_disable;
uniform sampler2D ocean_detail : filter_linear_mipmap, repeat_enable;
uniform vec4 deep : source_color = vec4(0.018, 0.125, 0.265, 1.0);
uniform vec4 shelf_blue : source_color = vec4(0.012, 0.29, 0.42, 1.0);
uniform vec4 lagoon : source_color = vec4(0.075, 0.48, 0.43, 1.0);
uniform vec4 breaker : source_color = vec4(0.90, 0.96, 0.92, 1.0);
varying vec3 surface_world;

// CoastalShelf encodes -48 to +16 metres. Texel centres match the terrain.
float shelf_raw(vec2 p) {
    return textureLod(coastal_shelf,(p+1025.0)/2048.0,0.0).r*64.0 - 48.0;
}
// The shelf is one sample per 2 m. Blur it so foam contours don't stairstep.
float shelf_blur(vec2 p) {
    vec2 o = vec2(2.4, 1.6);
    float h = shelf_raw(p);
    h += shelf_raw(p + o);
    h += shelf_raw(p - o);
    h += shelf_raw(p + vec2(o.x, -o.y));
    h += shelf_raw(p + vec2(-o.x, o.y));
    return h * 0.2;
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
    float depth=max(0.0,-shelf_blur(p));
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
    // Foam lines follow the seabed depth and drift toward the beach, then fade into the sand.
    float phase=TIME*.92+.37*sin(dot(p,vec2(.027,.016)))+.26*sin(b);
    float lace=texture(ocean_detail,p/27.0+tilt*.22+TIME*vec2(-.004,.007)).b;
    float lip_n=texture(ocean_detail,p/11.0+TIME*vec2(.02,-.015)).g;
    float drift=TIME*.18;
    float aa=max(fwidth(depth)*2.2,0.04);
    float band=depth*0.42+(lip_n-.5)*.35;
    float edge_a=min(fract(band-drift+.15*sin(phase)),1.0-fract(band-drift+.15*sin(phase)));
    float edge_b=min(fract(band-drift*.6+.38),1.0-fract(band-drift*.6+.38));
    float line_a=1.0-smoothstep(0.045,0.045+aa*2.5,edge_a);
    float line_b=1.0-smoothstep(0.02,0.02+aa*2.0,edge_b);
    float shallows=1.0-smoothstep(0.08,3.4,depth);
    float wash=shallows*(line_a*.55+line_b*.28)*mix(.25,1.0,lace);
    float lip=exp(-pow(abs(depth-(0.08+0.28*(0.5+0.5*sin(phase))))*3.2,2.0))*shallows*mix(.4,1.0,lace);
    float soft=(1.0-smoothstep(0.0,2.4,depth))*lace*0.28;
    float front=4.45-1.28*sin(phase-.9)+.40*cos(a*.72);
    float crest=(1.0-smoothstep(.2,1.4,abs(depth-front)))*smoothstep(.15,.75,.61*lace+.39*wind.b);
    crest*=smoothstep(.6,1.8,depth);
    float foam=clamp(wash+lip*.4+soft+crest*.35,0.0,0.85);
    ALBEDO=mix(water,breaker.rgb,foam);
    ROUGHNESS=mix(.19+.055*wind.b,.72,foam);
    SPECULAR=mix(.49,.18,foam);
    // Feather the water where the bottom meets the sand.
    float edge=smoothstep(0.0,1.15,depth+(lip_n-.5)*.25);
    float opacity=mix(.22,.995,1.0-exp(-depth*.29));
    opacity*=mix(.2,1.0,edge);
    ALPHA=clamp(opacity+foam*.28,0.0,1.0);
    ALPHA=mix(ALPHA,1.0,grazing*.55*smoothstep(.4,1.8,depth));
}
