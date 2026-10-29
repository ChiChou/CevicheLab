// Research only. Link with an independently built LibRaw; no app dependency.
#include <libraw/libraw.h>
#include <cstdio>
#include <algorithm>
int main(int argc, char **argv) {
    std::printf("LibRaw %s\n", LibRaw::version());
    for (int arg = 1; arg < argc; ++arg) {
        for (unsigned frame = 0; frame < 2; ++frame) {
            LibRaw raw;
            raw.imgdata.rawparams.options |= LIBRAW_RAWOPTIONS_DNG_ADD_ENHANCED;
            raw.imgdata.rawparams.shot_select = frame;
            int status = raw.open_file(argv[arg]);
            std::printf("%s frame=%u open=%d (%s)\n", argv[arg], frame, status, libraw_strerror(status));
            if (status) continue;
            auto &d = raw.imgdata;
            std::printf("frames=%u dimensions=%ux%u filters=%08x bits=%u white=%u black=%u decoder=%s\n",
                d.idata.raw_count, d.sizes.raw_width, d.sizes.raw_height, d.idata.filters,
                d.color.raw_bps, d.color.maximum, d.color.black, raw.unpack_function_name());
            status = raw.unpack();
            std::printf("unpack=%d (%s)\n", status, libraw_strerror(status));
            if (!status) {
                std::printf("buffer: CFA=%d RGB16=%d RGBX16=%d float1=%d float3=%d\n", d.rawdata.raw_image != nullptr,
                    d.rawdata.color3_image != nullptr, d.rawdata.color4_image != nullptr,
                    d.rawdata.float_image != nullptr, d.rawdata.float3_image != nullptr);
            }
            if (d.idata.raw_count <= 1) break;
        }
    }
}
