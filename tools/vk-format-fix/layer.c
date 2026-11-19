// VK_LAYER_BARCH_format_fix: hides VK_FORMAT_A2R10G10B10_UNORM_PACK32 from the surface formats
// a game sees, so it picks A2B10G10R10 instead.
//
// Why: on NVIDIA under Hyprland, a swapchain in A2R10G10B10 (DRM ARGB2101010) is shown with red
// and blue swapped: Hyprland reads it as ABGR2101010 (hyprwm/Hyprland#9557, closed as not planned).
// DOOM Eternal picks that format as soon as its HDR is on, and its red logo turns blue.
// A2B10G10R10 is offered with the same color spaces and shows right, so hiding the other one is
// enough; nothing else is touched.
//
// Implicit layer, enabled only when BARCH_VK_FORMAT_FIX=1 (set by Steam's and Battle.net's
// launchers in games/). Built and installed by tools/vk-format-fix/build.sh.

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#define EXPORT __attribute__((visibility("default")))
#define HIDDEN VK_FORMAT_A2R10G10B10_UNORM_PACK32

// The next layer's entry points are plain functions shared by every instance and device of the
// process (they dispatch on the handle), so one global copy of each is enough.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static PFN_vkGetInstanceProcAddr next_gipa;
static PFN_vkGetDeviceProcAddr next_gdpa;
static PFN_vkGetPhysicalDeviceSurfaceFormatsKHR next_formats;
static PFN_vkGetPhysicalDeviceSurfaceFormats2KHR next_formats2;

static VkLayerInstanceCreateInfo *instance_link(const VkInstanceCreateInfo *info) {
    for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext) {
        VkLayerInstanceCreateInfo *l = (VkLayerInstanceCreateInfo *)s;
        if (s->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && l->function == VK_LAYER_LINK_INFO)
            return l;
    }
    return NULL;
}

static VkLayerDeviceCreateInfo *device_link(const VkDeviceCreateInfo *info) {
    for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext) {
        VkLayerDeviceCreateInfo *l = (VkLayerDeviceCreateInfo *)s;
        if (s->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && l->function == VK_LAYER_LINK_INFO)
            return l;
    }
    return NULL;
}

static VKAPI_ATTR VkResult VKAPI_CALL fix_CreateInstance(const VkInstanceCreateInfo *info,
        const VkAllocationCallbacks *alloc, VkInstance *instance) {
    VkLayerInstanceCreateInfo *link = instance_link(info);
    if (!link) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult r = create(info, alloc, instance);
    if (r != VK_SUCCESS) return r;
    pthread_mutex_lock(&lock);
    next_gipa = gipa;
    next_formats = (PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)
        gipa(*instance, "vkGetPhysicalDeviceSurfaceFormatsKHR");
    next_formats2 = (PFN_vkGetPhysicalDeviceSurfaceFormats2KHR)
        gipa(*instance, "vkGetPhysicalDeviceSurfaceFormats2KHR");
    pthread_mutex_unlock(&lock);
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL fix_CreateDevice(VkPhysicalDevice gpu, const VkDeviceCreateInfo *info,
        const VkAllocationCallbacks *alloc, VkDevice *device) {
    VkLayerDeviceCreateInfo *link = device_link(info);
    if (!link) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(VK_NULL_HANDLE, "vkCreateDevice");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult r = create(gpu, info, alloc, device);
    if (r == VK_SUCCESS) {
        pthread_mutex_lock(&lock);
        next_gdpa = gdpa;
        pthread_mutex_unlock(&lock);
    }
    return r;
}

// Both queries follow Vulkan's two-call idiom: ask the driver for everything, drop the hidden
// format, then answer the count query or fill the caller's array (VK_INCOMPLETE when it is short).
static VKAPI_ATTR VkResult VKAPI_CALL fix_GetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice gpu,
        VkSurfaceKHR surface, uint32_t *count, VkSurfaceFormatKHR *formats) {
    uint32_t n = 0;
    VkResult r = next_formats(gpu, surface, &n, NULL);
    if (r != VK_SUCCESS || n == 0) { *count = 0; return r; }
    VkSurfaceFormatKHR *all = malloc(n * sizeof *all);
    if (!all) return VK_ERROR_OUT_OF_HOST_MEMORY;
    r = next_formats(gpu, surface, &n, all);
    if (r < 0) { free(all); return r; }
    uint32_t kept = 0;
    for (uint32_t i = 0; i < n; i++)
        if (all[i].format != HIDDEN) all[kept++] = all[i];
    if (!formats) { *count = kept; free(all); return VK_SUCCESS; }
    uint32_t out = kept < *count ? kept : *count;
    memcpy(formats, all, out * sizeof *all);
    *count = out;
    free(all);
    return out < kept ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL fix_GetPhysicalDeviceSurfaceFormats2KHR(VkPhysicalDevice gpu,
        const VkPhysicalDeviceSurfaceInfo2KHR *info, uint32_t *count, VkSurfaceFormat2KHR *formats) {
    uint32_t n = 0;
    VkResult r = next_formats2(gpu, info, &n, NULL);
    if (r != VK_SUCCESS || n == 0) { *count = 0; return r; }
    VkSurfaceFormat2KHR *all = calloc(n, sizeof *all);
    if (!all) return VK_ERROR_OUT_OF_HOST_MEMORY;
    for (uint32_t i = 0; i < n; i++) all[i].sType = VK_STRUCTURE_TYPE_SURFACE_FORMAT_2_KHR;
    r = next_formats2(gpu, info, &n, all);
    if (r < 0) { free(all); return r; }
    uint32_t kept = 0;
    for (uint32_t i = 0; i < n; i++)
        if (all[i].surfaceFormat.format != HIDDEN) all[kept++] = all[i];
    if (!formats) { *count = kept; free(all); return VK_SUCCESS; }
    uint32_t out = kept < *count ? kept : *count;
    // only the surfaceFormat member: the caller's sType/pNext chain stays its own
    for (uint32_t i = 0; i < out; i++) formats[i].surfaceFormat = all[i].surfaceFormat;
    *count = out;
    free(all);
    return out < kept ? VK_INCOMPLETE : VK_SUCCESS;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL fix_GetDeviceProcAddr(VkDevice device, const char *name) {
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)fix_GetDeviceProcAddr;
    return next_gdpa ? next_gdpa(device, name) : NULL;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL fix_GetInstanceProcAddr(VkInstance instance, const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)fix_GetInstanceProcAddr;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)fix_CreateInstance;
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)fix_CreateDevice;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)fix_GetDeviceProcAddr;
    if (!next_gipa) return NULL;
    PFN_vkVoidFunction f = next_gipa(instance, name);
    if (!f) return NULL;   // not supported below: keep it unsupported
    if (!strcmp(name, "vkGetPhysicalDeviceSurfaceFormatsKHR") && next_formats)
        return (PFN_vkVoidFunction)fix_GetPhysicalDeviceSurfaceFormatsKHR;
    if (!strcmp(name, "vkGetPhysicalDeviceSurfaceFormats2KHR") && next_formats2)
        return (PFN_vkVoidFunction)fix_GetPhysicalDeviceSurfaceFormats2KHR;
    return f;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL fix_NegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
    if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
    v->pfnGetInstanceProcAddr = fix_GetInstanceProcAddr;
    v->pfnGetDeviceProcAddr = fix_GetDeviceProcAddr;
    v->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
