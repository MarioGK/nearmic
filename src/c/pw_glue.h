#pragma once
#include <stdint.h>

int nm_pw_open(const char *target_node);
void nm_pw_close(void);
const char *nm_pw_last_error(void);
uint32_t nm_pw_node_id(void);

uint32_t nm_in_read(float *dst, uint32_t n);
uint32_t nm_out_write(const float *src, uint32_t n);
uint32_t nm_listen_write(const float *src, uint32_t n);
int nm_source_streaming(void);
void nm_set_listen(int enabled);
uint64_t nm_underruns(void);
long nm_clk_tck(void);
