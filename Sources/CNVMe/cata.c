#include "cata.h"
#include <stdlib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>

struct nvmeter_ata_handle {
    IOCFPlugInInterface **plug;
    IOATASMARTInterface **smart;
};

nvmeter_ata_handle *nvmeter_ata_open(io_service_t service, int *err) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, kIOATASMARTUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != kIOReturnSuccess || plug == NULL) {
        if (err) *err = kr ? kr : -1;
        return NULL;
    }
    IOATASMARTInterface **smart = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plug);
        if (err) *err = (int)hr ? (int)hr : -2;
        return NULL;
    }
    nvmeter_ata_handle *h = calloc(1, sizeof(*h));
    h->plug = plug;
    h->smart = smart;
    return h;
}

void nvmeter_ata_close(nvmeter_ata_handle *h) {
    if (!h) return;
    if (h->smart) (*h->smart)->Release(h->smart);
    if (h->plug) IODestroyPlugInInterface(h->plug);
    free(h);
}

int nvmeter_ata_identify(nvmeter_ata_handle *h, uint8_t *buf512) {
    if (!h) return kIOReturnBadArgument;
    UInt32 out = 0;
    return (*h->smart)->GetATAIdentifyData(h->smart, buf512, 512, &out);
}

int nvmeter_ata_read_data(nvmeter_ata_handle *h, uint8_t *buf512) {
    if (!h) return kIOReturnBadArgument;
    _Static_assert(sizeof(ATASMARTData) == 512, "ATASMARTData must be 512 bytes");
    return (*h->smart)->SMARTReadData(h->smart, (ATASMARTData *)buf512);
}

int nvmeter_ata_read_thresholds(nvmeter_ata_handle *h, uint8_t *buf512) {
    if (!h) return kIOReturnBadArgument;
    _Static_assert(sizeof(ATASMARTDataThresholds) == 512, "thresholds must be 512 bytes");
    return (*h->smart)->SMARTReadDataThresholds(h->smart, (ATASMARTDataThresholds *)buf512);
}

int nvmeter_ata_return_status(nvmeter_ata_handle *h, int *exceeded) {
    if (!h) return kIOReturnBadArgument;
    Boolean ex = 0;
    IOReturn kr = (*h->smart)->SMARTReturnStatus(h->smart, &ex);
    if (exceeded) *exceeded = ex ? 1 : 0;
    return kr;
}
