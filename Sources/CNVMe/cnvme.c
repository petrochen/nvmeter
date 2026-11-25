#include "cnvme.h"
#include <stdlib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

struct nvmeter_handle {
    IOCFPlugInInterface **plug;
    IONVMeSMARTInterface **smart;
};

nvmeter_handle *nvmeter_open(io_service_t service, int *err) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != kIOReturnSuccess || plug == NULL) {
        if (err) *err = kr ? kr : -1;
        return NULL;
    }
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                                         (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plug);
        if (err) *err = (int)hr ? (int)hr : -2;
        return NULL;
    }
    nvmeter_handle *h = calloc(1, sizeof(*h));
    h->plug = plug;
    h->smart = smart;
    return h;
}

void nvmeter_close(nvmeter_handle *h) {
    if (!h) return;
    if (h->smart) (*h->smart)->Release(h->smart);
    if (h->plug) IODestroyPlugInInterface(h->plug);
    free(h);
}

int nvmeter_read_smart(nvmeter_handle *h, uint8_t *buf512) {
    if (!h) return kIOReturnBadArgument;
    _Static_assert(sizeof(NVMeSMARTData) == 512, "NVMeSMARTData must be 512 bytes");
    return (*h->smart)->SMARTReadData(h->smart, (NVMeSMARTData *)buf512);
}

int nvmeter_read_identify(nvmeter_handle *h, uint8_t *buf4096) {
    if (!h) return kIOReturnBadArgument;
    return (*h->smart)->GetIdentifyData(h->smart, buf4096, 0);
}

// NVMe Get Log Page (read-only). `dwords` is the real length in dwords (the interface wants it zero based).
int nvmeter_read_log_page(nvmeter_handle *h, uint8_t lid, uint8_t *buf, uint32_t dwords) {
    if (!h || !buf || dwords == 0) return kIOReturnBadArgument;
    return (*h->smart)->GetLogPage(h->smart, buf, lid, dwords - 1);
}
