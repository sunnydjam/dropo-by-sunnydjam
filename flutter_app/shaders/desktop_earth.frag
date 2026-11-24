#version 460 core
#include <flutter/runtime_effect.glsl>

uniform float uRadius;
uniform float uLongitude;
uniform float uCityBrightness;
uniform vec3 uTerrainTint;
uniform float uGrayscale;
uniform sampler2D uAtlas;

out vec4 fragColor;

const float pi = 3.14159265359;

void main() {
  vec2 point = FlutterFragCoord().xy / uRadius;
  float radiusSquared = dot(point, point);
  if (radiusSquared > 1.015) {
    fragColor = vec4(0.0);
    return;
  }

  float depth = sqrt(max(0.0, 1.0 - radiusSquared));
  // Project the visible hemisphere onto the bundled equirectangular surface.
  // Tilt the rotation axis and pitch the equator slightly below centre.
  vec2 upright = mat2(0.978, -0.208, 0.208, 0.978) * vec2(point.x, -point.y);
  vec3 normal = vec3(
    upright.x,
    upright.y * 0.956 + depth * 0.292,
    depth * 0.956 - upright.y * 0.292
  );
  vec2 uv = vec2(
    fract(0.5 + atan(normal.x, normal.z) / (2.0 * pi) + uLongitude),
    0.5 - asin(clamp(normal.y, -1.0, 1.0)) / pi
  );
  vec3 sampleColor = texture(uAtlas, uv).rgb;

  // The atlas uses warm colours for lights and cool colours for terrain.
  float warmth = smoothstep(0.035, 0.31, sampleColor.r - sampleColor.b);
  float emission = warmth * smoothstep(0.18, 0.68, sampleColor.r);
  vec3 terrain = sampleColor * uTerrainTint * (0.48 + 0.72 * depth);
  vec3 city = mix(sampleColor, vec3(1.0, 0.82, 0.48), 0.48);
  vec3 surface = mix(terrain, city, emission * uCityBrightness);
  surface += (vec3(0.13, 0.26, 0.25) * uTerrainTint) *
      pow(1.0 - depth, 4.0);
  float luma = dot(sampleColor, vec3(0.2126, 0.7152, 0.0722));
  float unlit = mix(luma, min(luma, 0.125), emission);
  float gray = (0.035 + unlit * 1.14) * (0.63 + 0.49 * depth) +
      0.11 * pow(1.0 - depth, 4.0);
  surface = mix(surface, vec3(gray), uGrayscale);

  float alpha = 1.0 - smoothstep(0.985, 1.006, sqrt(radiusSquared));
  fragColor = vec4(clamp(surface, 0.0, 1.0) * alpha, alpha);
}
