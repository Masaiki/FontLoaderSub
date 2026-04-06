#import "FLBridge.h"

NSString *FLWCharToNSString(const wchar_t *w) {
    if (w == NULL) {
        return nil;
    }

    size_t length = 0;
    while (w[length] != 0) {
        length++;
    }

    return [[[NSString alloc] initWithCharacters:(const unichar *)w length:length] autorelease];
}

wchar_t *FLNSStringToWChar(NSString *s) {
    if (s == nil) {
        return NULL;
    }

    NSUInteger length = [s length];
    wchar_t *buffer = calloc(length + 1, sizeof(wchar_t));
    if (buffer == NULL) {
        return NULL;
    }

    [s getCharacters:(unichar *)buffer range:NSMakeRange(0, length)];
    buffer[length] = 0;
    return buffer;
}
