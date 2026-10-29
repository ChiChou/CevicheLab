// Research benchmark bridge. LibRaw is used only for the denoise input.
#include <libraw/libraw.h>
#include <chrono>
struct Frame { LibRaw raw; double openSeconds, unpackSeconds; };
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
extern "C" void *speed_raw_open(const char *path) {
    Frame *f = new Frame;
    double t=now();int status=f->raw.open_file(path);f->openSeconds=now()-t;
    if(status) { delete f;return nullptr; }
    t=now();status=f->raw.unpack();f->unpackSeconds=now()-t;
    if(status || !f->raw.imgdata.rawdata.raw_image) { delete f;return nullptr; }
    return f;
}
extern "C" const unsigned short *speed_raw_pixels(void *p) { return static_cast<Frame*>(p)->raw.imgdata.rawdata.raw_image; }
extern "C" void speed_raw_info(void *p,int *info,double *times) {
    auto &f=*static_cast<Frame*>(p); auto &s=f.raw.imgdata.sizes; auto &c=f.raw.imgdata.color;
    info[0]=s.width;info[1]=s.height;info[2]=s.raw_pitch/2;info[3]=s.top_margin;info[4]=s.left_margin;
    info[5]=c.black;info[6]=c.maximum;
    for(int i=0;i<4;i++) { info[7+i]=f.raw.COLOR(s.top_margin+i/2,s.left_margin+i%2);info[11+i]=c.cblack[i]; }
    times[0]=f.openSeconds;times[1]=f.unpackSeconds;
}
extern "C" void speed_raw_close(void *p) { delete static_cast<Frame*>(p); }
