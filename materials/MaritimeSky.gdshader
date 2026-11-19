shader_type sky;

// Sky texture adapted from Poly Haven's CC0 Kloofendal 48d Partly Cloudy (Pure Sky).
// https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky
uniform sampler2D trade_clouds : source_color, repeat_enable, filter_linear_mipmap;
void sky() {
    vec3 d = EYEDIR;
    float sun_azimuth = LIGHT0_ENABLED ? atan(LIGHT0_DIRECTION.z,LIGHT0_DIRECTION.x) : 0.0;
    float longitude = (atan(d.z,d.x)-sun_azimuth)/TAU + .59473;
    float latitude = acos(clamp(d.y,-1.0,1.0))/PI;
    vec3 photographed=texture(trade_clouds,vec2(longitude,clamp(latitude,.001,.509))).rgb;
    vec3 marine_haze=vec3(.64,.78,.85);
    COLOR=mix(marine_haze,photographed,smoothstep(-.025,.125,d.y));
}
