/* river_accum.c - 流量累积 C 加速器
 *
 * 输入：
 *   flow_dir.bin  : int8[SIZE*SIZE]   D8 流向（-1=无, -2=海洋, 0-7=方向）
 *   rainfall.bin  : float32[SIZE*SIZE] 降雨量场
 *   mask.bin      : uint8[SIZE*SIZE]   大陆掩码
 *
 * 输出：
 *   accum.bin     : float32[SIZE*SIZE]  流量累积场
 *
 * 算法：Kahn 拓扑排序
 *   1. 每格初始流量 = 降雨量
 *   2. 计算入度（多少上游格子指向当前格子）
 *   3. 入度=0 的格子入队
 *   4. 拓扑排序：每格流量累加到下游
 *
 * 编译: gcc -O3 -ffast-math -march=native -o river_accum.exe river_accum.c -lm
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define SIZE 8192
#define TOTAL (SIZE * SIZE)

static const int DX[8] = {0, 1, 1, 1, 0, -1, -1, -1};
static const int DY[8] = {-1, -1, 0, 1, 1, 1, 0, -1};

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "用法: %s <flow_dir.bin> <rainfall.bin> <mask.bin> <accum.bin>\n", argv[0]);
        return 1;
    }

    int8_t  *flow_dir = (int8_t*)malloc(sizeof(int8_t) * TOTAL);
    float   *rain     = (float*)malloc(sizeof(float) * TOTAL);
    uint8_t *mask     = (uint8_t*)malloc(sizeof(uint8_t) * TOTAL);
    float   *accum    = (float*)calloc(TOTAL, sizeof(float));
    int16_t *in_deg   = (int16_t*)calloc(TOTAL, sizeof(int16_t));

    if (!flow_dir || !rain || !mask || !accum || !in_deg) {
        fprintf(stderr, "内存分配失败\n");
        return 2;
    }

    /* 加载数据 */
    FILE *f;
    f = fopen(argv[1], "rb"); fread(flow_dir, sizeof(int8_t), TOTAL, f); fclose(f);
    f = fopen(argv[2], "rb"); fread(rain, sizeof(float), TOTAL, f); fclose(f);
    f = fopen(argv[3], "rb"); fread(mask, sizeof(uint8_t), TOTAL, f); fclose(f);

    fprintf(stderr, "数据加载完成\n");

    /* 初始化流量 = 降雨量 */
    int n_land = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (mask[i]) {
            accum[i] = rain[i];
            n_land++;
        }
    }
    fprintf(stderr, "陆地格子: %d\n", n_land);

    /* 计算入度 */
    for (int i = 0; i < TOTAL; i++) {
        if (!mask[i]) continue;
        int fd = flow_dir[i];
        if (fd < 0) continue;  /* 无流向 */

        int x = i % SIZE, y = i / SIZE;
        int down = (y + DY[fd]) * SIZE + (x + DX[fd]);
        if (down >= 0 && down < TOTAL && mask[down]) {
            in_deg[down]++;
        }
    }

    /* FIFO 队列 */
    int *fifo = (int*)malloc(sizeof(int) * TOTAL);
    int head = 0, tail = 0;

    /* 入度=0 的格子入队 */
    int n_sources = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (mask[i] && in_deg[i] == 0) {
            fifo[tail++] = i;
            n_sources++;
        }
    }
    fprintf(stderr, "源头格子: %d\n", n_sources);

    /* Kahn 拓扑排序 */
    long processed = 0;
    while (head < tail) {
        int idx = fifo[head++];
        int fd = flow_dir[idx];
        if (fd < 0) continue;

        int x = idx % SIZE, y = idx / SIZE;
        int down = (y + DY[fd]) * SIZE + (x + DX[fd]);
        if (down < 0 || down >= TOTAL) continue;

        /* 累加流量到下游 */
        accum[down] += accum[idx];

        /* 减少下游入度 */
        if (mask[down]) {
            in_deg[down]--;
            if (in_deg[down] == 0) {
                fifo[tail++] = down;
            }
        }

        processed++;
        if (processed % 10000000 == 0)
            fprintf(stderr, "  accum %ld/%d\n", processed, n_land);
    }

    fprintf(stderr, "流量累积完成 (处理 %ld 格)\n", processed);

    /* 统计 */
    float max_accum = 0;
    double total_accum = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (mask[i] && accum[i] > max_accum) max_accum = accum[i];
        if (mask[i]) total_accum += accum[i];
    }
    fprintf(stderr, "最大流量累积: %.1f, 总流量: %.0f\n", max_accum, total_accum);

    /* 输出 */
    f = fopen(argv[4], "wb");
    fwrite(accum, sizeof(float), TOTAL, f);
    fclose(f);
    fprintf(stderr, "accum -> %s\n", argv[4]);

    free(flow_dir); free(rain); free(mask); free(accum); free(in_deg); free(fifo);
    fprintf(stderr, "完成。\n");
    return 0;
}
