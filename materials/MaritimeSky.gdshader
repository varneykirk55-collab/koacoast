shader_type sky;

// Sky texture adapted from Poly Haven's CC0 Kloofendal 48d Partly Cloudy (Pure Sky).
// https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky
uniform sampler2D trade_clouds : source_color, repeat_enable, filter_linear_mipmap;
uniform float weather_cloud : hint_range(0.0, 1.0) = 0.0;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float twilight_factor : hint_range(0.0, 1.0) = 0.0;

void sky() {
    vec3 d = EYEDIR;
    float sun_azimuth = LIGHT0_ENABLED ? atan(LIGHT0_DIRECTION.z,LIGHT0_DIRECTION.x) : 0.0;
    float longitude = (atan(d.z,d.x)-sun_azimuth)/TAU + .59473;
    float latitude = acos(clamp(d.y,-1.0,1.0))/PI;
    vec3 photographed=texture(trade_clouds,vec2(longitude,clamp(latitude,.001,.509))).rgb;
    vec3 marine_haze=vec3(.64,.78,.85);
    vec3 day_col=mix(marine_haze,photographed,smoothstep(-.025,.125,d.y));

    float cloud = smoothstep(.06,.65,dot(photographed, vec3(.30,.55,.15)));
    day_col = mix(day_col, mix(vec3(.33,.39,.43),vec3(.63,.68,.70),cloud),weather_cloud * .85);
    // Warm sunset / sunrise horizon blend.
    float horizon = 1.0 - smoothstep(0.0, 0.38, max(d.y, 0.0));
    vec3 twilight_tint = mix(vec3(0.42, 0.36, 0.48), vec3(0.95, 0.54, 0.30), horizon);
    vec3 sky_col = mix(day_col, day_col * 0.55 + twilight_tint * 0.48, twilight_factor);

    // Tropical moonlit night sky preserving mountain & coastline silhouettes.
    vec3 night_horizon = vec3(0.055, 0.085, 0.145);
    vec3 night_zenith = vec3(0.015, 0.025, 0.055);
    vec3 night_col = mix(night_horizon, night_zenith, smoothstep(-0.02, 0.55, d.y));
    float cloud_sil = dot(photographed, vec3(0.3, 0.5, 0.2));
    night_col += vec3(0.02, 0.03, 0.05) * cloud_sil * (1.0 - horizon * 0.5);
    // Subtle stars high in the sky at night.
    vec2 star_cell = floor(vec2(longitude * 220.0, latitude * 110.0));
    float star_hash = fract(sin(dot(star_cell, vec2(127.1, 311.7))) * 43758.5453);
    float star = step(0.9965, star_hash) * smoothstep(0.18, 0.55, d.y);
    night_col += vec3(0.75, 0.82, 0.95) * star * 0.65 * (1.0-weather_cloud);

    COLOR = mix(sky_col, night_col, night_factor);
}
