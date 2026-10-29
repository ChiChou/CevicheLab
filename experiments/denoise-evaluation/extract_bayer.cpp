// Research-only LibRaw unpack. Does not demosaic or alter the original file.
#include <libraw/libraw.h>
#include <cstdio>
#include <string>
#include <stdexcept>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    LibRaw raw;
    int err = raw.open_file(argv[1]); if (!err) err = raw.unpack();
    if (err) { std::fprintf(stderr,"%s\n",libraw_strerror(err)); return 1; }
    auto &d = raw.imgdata; auto &s = d.sizes; auto &c = d.color;
    if (!d.rawdata.raw_image || !d.idata.filters) return 3;
    std::string base(argv[2]);
    FILE *f = std::fopen((base+".bayer16").c_str(),"wb"); if (!f) return 4;
    for (unsigned y=0; y<s.height; ++y)
        std::fwrite(reinterpret_cast<unsigned char*>(d.rawdata.raw_image)+(y+s.top_margin)*s.raw_pitch+s.left_margin*2,2,s.width,f);
    std::fclose(f);
    f = std::fopen((base+"-bayer.json").c_str(),"w"); if (!f) return 4;
    std::fprintf(f,"{\"libraw\":\"%s\",\"width\":%u,\"height\":%u,\"rawWidth\":%u,\"rawHeight\":%u,\"top\":%u,\"left\":%u,\"white\":%u,\"black\":%u,\"iso\":%f,\"pattern\":[",LibRaw::version(),s.width,s.height,s.raw_width,s.raw_height,s.top_margin,s.left_margin,c.maximum,c.black,d.other.iso_speed);
    for(int y=0;y<2;y++) for(int x=0;x<2;x++) std::fprintf(f,"%s%d",y||x?",":"",raw.COLOR(y+s.top_margin,x+s.left_margin));
    std::fprintf(f,"],\"colorDescription\":\"%s\",\"channelBlack\":[%u,%u,%u,%u],\"camMul\":[%f,%f,%f,%f],\"rgbCam\":[",d.idata.cdesc,c.cblack[0],c.cblack[1],c.cblack[2],c.cblack[3],c.cam_mul[0],c.cam_mul[1],c.cam_mul[2],c.cam_mul[3]);
    for(int y=0;y<3;y++) for(int x=0;x<4;x++) std::fprintf(f,"%s%.9g",y||x?",":"",c.rgb_cam[y][x]);
    std::fprintf(f,"],\"camXYZ\":[");
    for(int y=0;y<4;y++) for(int x=0;x<3;x++) std::fprintf(f,"%s%.9g",y||x?",":"",c.cam_xyz[y][x]);
    std::fprintf(f,"]}\n"); std::fclose(f);
}
