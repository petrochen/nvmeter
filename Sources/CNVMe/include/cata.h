// Minimal C shim around Apple's IOATASMARTInterface (ATASMARTLib), same style as cnvme.h.
// Strictly read-only: IDENTIFY DEVICE, SMART READ DATA, SMART READ THRESHOLDS, SMART RETURN STATUS.
// It never enables or disables SMART, never starts a self-test and never writes a log.
#ifndef CATA_H
#define CATA_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct nvmeter_ata_handle nvmeter_ata_handle;

// Opens the ATA SMART plug-in on an IOBlockStorageDevice that has "SMART Capable" = true.
nvmeter_ata_handle *nvmeter_ata_open(io_service_t service, int *err);
void nvmeter_ata_close(nvmeter_ata_handle *h);

// 512 bytes of IDENTIFY DEVICE data (native-endian 16-bit words).
int nvmeter_ata_identify(nvmeter_ata_handle *h, uint8_t *buf512);
// 512 bytes SMART data (attribute table at offset 2).
int nvmeter_ata_read_data(nvmeter_ata_handle *h, uint8_t *buf512);
// 512 bytes SMART thresholds (same layout). May fail on drives that do not implement it.
int nvmeter_ata_read_thresholds(nvmeter_ata_handle *h, uint8_t *buf512);
// Overall status: *exceeded = 1 when the drive reports a threshold-exceeded condition (SMART FAILING).
int nvmeter_ata_return_status(nvmeter_ata_handle *h, int *exceeded);

#endif
