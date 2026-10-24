// Overlay.hpp —— 呈现层对外接口
#pragma once
#include <stdint.h>

struct AimSettingsBox {
    float fov = 25.f;
    float smooth = 0.25f;
    bool  team = true;
};

void overlay_install();
bool overlay_ready();
void overlay_set_screen(float w, float h);
