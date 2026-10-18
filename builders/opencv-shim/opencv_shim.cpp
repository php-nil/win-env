// opencv_shim.cpp — OpenCV 的 C 封装（供调用方运行时 raw FFI 使用）。
//
// 动机：调用方不做任何 OpenCV 绑定生成（避免 libclang/bindgen），只通过运行时
// LoadLibrary 加载本 DLL，把需要的 OpenCV 能力收敛成一个 extern "C" 函数。
//
// 导出（C 链接、无名字修饰）：
//   shim_match_template()  cv::matchTemplate（TM_CCOEFF_NORMED）
//
// 工具链：为什么用「自编译的 MinGW OpenCV」
//
// 官方的 OpenCV Windows 预编译包是 MSVC 编译的（x64/vc16）。本 shim 只用到
// `cv::matchTemplate`，它有等价的 **C API**（`cvMatchTemplate`），C 链接导出、
// 无名字修饰，MinGW g++ 可以直接链接。但为了链接稳定、发布包自包含，我们仍
// 统一使用同工具链从源码编出的 MinGW OpenCV（见 builders/opencv-shim/build.ps1）。
//
// 分发：本 shim 静态链接 OpenCV（BUILD_SHARED_LIBS=OFF）与 MinGW 运行库，
// 因此**自包含**——不需要 opencv_world*.dll / msvcp140.dll 那一堆。

#include <opencv2/core/core_c.h>
#include <opencv2/imgproc/imgproc_c.h>

#include <cstdint>
#include <cmath>

extern "C" {

/// 在 screen 灰度图（sw x sh，行连续）中查找 template（tw x th）的最佳位置，
/// 使用归一化互相关 TM_CCOEFF_NORMED。
///
/// 返回：
///   1  → 找到，*out_x / *out_y / *out_score 有效（score ∈ [0,1]）
///   0  → 无有效位置（模板大于屏幕，或结果退化/NaN）
///  -1  → 内部异常
__declspec(dllexport)
int shim_match_template(
    const uint8_t* screen, int sw, int sh,
    const uint8_t* tpl,   int tw, int th,
    int* out_x, int* out_y, float* out_score)
{
    if (!screen || !tpl || sw <= 0 || sh <= 0 || tw <= 0 || th <= 0 ||
        tw > sw || th > sh) {
        return 0;
    }
    try {
        // 零拷贝构造 CvMat（data 为行连续灰度，step = width）。
        CvMat scr, tmp;
        cvInitMatHeader(&scr, sh, sw, CV_8UC1, const_cast<void*>((const void*)screen));
        cvInitMatHeader(&tmp, th, tw, CV_8UC1, const_cast<void*>((const void*)tpl));

        // 结果矩阵 (sh-th+1) x (sw-tw+1)，单通道 float。
        CvMat* result = cvCreateMat(sh - th + 1, sw - tw + 1, CV_32FC1);

        cvMatchTemplate(&scr, &tmp, result, CV_TM_CCOEFF_NORMED);

        double min_val = 0.0, max_val = 0.0;
        CvPoint min_loc, max_loc;
        cvMinMaxLoc(result, &min_val, &max_val, &min_loc, &max_loc, NULL);
        cvReleaseMat(&result);

        // TM_CCOEFF_NORMED 在平坦模板/区域上会得到 NaN，按「无有效位置」处理。
        if (std::isnan(max_val)) {
            return 0;
        }
        float s = (float)max_val;
        if (s < 0.0f) s = 0.0f;
        if (s > 1.0f) s = 1.0f;

        *out_x = max_loc.x;
        *out_y = max_loc.y;
        *out_score = s;
        return 1;
    } catch (...) {
        return -1;
    }
}

} // extern "C"
