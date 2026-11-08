#import <Foundation/Foundation.h>

typedef struct {
    NSUInteger count;
    int width;
    int height;
    unsigned int error;
    unsigned char pixels[4][4];
} RuntimeCapture;

void InstallRuntimeCapture(void);
RuntimeCapture LatestRuntimeCapture(void);
