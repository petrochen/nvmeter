// Minimal C shim around Apple's IONVMeSMARTInterface (IOCFPlugIn / COM style vtable).
// This is the only non-Swift code in NVMeter. It is strictly read-only: it issues
// the NVMe "Get Log Page (SMART / Health)" and "Identify" admin commands via Apple's driver.
#ifndef CNVME_H
#define CNVME_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct nvmeter_handle nvmeter_handle;

// Opens the SMART user client plug-in on an IONVMeBlockStorageDevice-like service.
// Returns NULL and sets *err (IOReturn or HRESULT) on failure.
nvmeter_handle *nvmeter_open(io_service_t service, int *err);
void nvmeter_close(nvmeter_handle *h);

// Fills 512 bytes with the raw NVMe SMART / Health Information log page (LID 02h).
int nvmeter_read_smart(nvmeter_handle *h, uint8_t *buf512);
// Fills 4096 bytes with Identify Controller data (CNS 01h).
int nvmeter_read_identify(nvmeter_handle *h, uint8_t *buf4096);

#endif
