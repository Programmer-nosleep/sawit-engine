#ifndef MOUNTAIN_RENDER_H
#define MOUNTAIN_RENDER_H

#include "palm_render.h"

typedef PalmRenderMesh MountainRenderMesh;

int mountain_render_create(MountainRenderMesh* mesh);
void mountain_render_destroy(MountainRenderMesh* mesh);
int mountain_render_update(
  MountainRenderMesh* mesh,
  const CameraState* camera,
  const SceneSettings* settings,
  const RendererQualityProfile* quality);
void mountain_render_draw(const MountainRenderMesh* mesh);

#endif
