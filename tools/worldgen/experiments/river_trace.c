/* river_trace.c - 河流路径追踪 C 加速器
 *
 * 从流量累积场阈值化提取河流格子，沿 flow_dir 追踪路径。
 *
 * 输入：
 *   flow_dir.bin  : int8[SIZE*SIZE]   D8 流向
 *   accum.bin     : float32[SIZE*SIZE] 流量累积
 *   mask.bin      : uint8[SIZE*SIZE]   大陆掩码
 *
 * 输出：
 *   paths.bin     : 裸二进制路径数据
 *     格式: [n_paths:int32]
 *           对每条路径: [path_len:int32] [x0,y0,x1,y1,... int16*path_len]
 *           [n_paths:int32] (重复，用于校验)
 *
 * 编译: gcc -O3 -ffast-math -march=native -o river_trace.exe river_trace.c -lm
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
    if (argc < 6) {
        fprintf(stderr, "用法: %s <flow_dir.bin> <accum.bin> <mask.bin> <threshold> <paths.bin>\n", argv[0]);
        return 1;
    }

    float threshold = atof(argv[4]);

    int8_t  *flow_dir = (int8_t*)malloc(sizeof(int8_t) * TOTAL);
    float   *accum    = (float*)malloc(sizeof(float) * TOTAL);
    uint8_t *mask     = (uint8_t*)malloc(sizeof(uint8_t) * TOTAL);

    FILE *f;
    f = fopen(argv[1], "rb"); fread(flow_dir, sizeof(int8_t), TOTAL, f); fclose(f);
    f = fopen(argv[2], "rb"); fread(accum, sizeof(float), TOTAL, f); fclose(f);
    f = fopen(argv[3], "rb"); fread(mask, sizeof(uint8_t), TOTAL, f); fclose(f);

    fprintf(stderr, "数据加载完成, threshold=%.0f\n", threshold);

    /* 河流掩码 */
    uint8_t *river = (uint8_t*)calloc(TOTAL, sizeof(uint8_t));
    int n_river = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (mask[i] && accum[i] > threshold) {
            river[i] = 1;
            n_river++;
        }
    }
    fprintf(stderr, "河流格子: %d\n", n_river);

    /* 计算上游河流格子数 */
    int16_t *upstream = (int16_t*)calloc(TOTAL, sizeof(int16_t));
    for (int y = 0; y < SIZE; y++) {
        for (int x = 0; x < SIZE; x++) {
            int idx = y * SIZE + x;
            if (!river[idx]) continue;
            int fd = flow_dir[idx];
            if (fd < 0) continue;
            int nx = x + DX[fd], ny = y + DY[fd];
            if (nx < 0 || nx >= SIZE || ny < 0 || ny >= SIZE) continue;
            int down = ny * SIZE + nx;
            if (river[down]) upstream[down]++;
        }
    }

    /* 找源头 */
    int *sources = (int*)malloc(sizeof(int) * n_river);
    int n_sources = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (river[i] && upstream[i] == 0) {
            sources[n_sources++] = i;
        }
    }
    fprintf(stderr, "源头数: %d\n", n_sources);

    /* 追踪路径 */
    uint8_t *visited = (uint8_t*)calloc(TOTAL, sizeof(uint8_t));

    /* 路径点缓冲区：最大路径长度不超过河流格子总数 */
    int16_t *path_buf = (int16_t*)malloc(sizeof(int16_t) * 2 * n_river);

    f = fopen(argv[5], "wb");
    /* 先写占位的 n_paths */
    int n_paths = 0;
    fwrite(&n_paths, sizeof(int32_t), 1, f);

    for (int s = 0; s < n_sources; s++) {
        int start = sources[s];

        /* 追踪并收集路径点 */
        int cx = start % SIZE, cy = start / SIZE;
        int path_len = 0;

        while (1) {
            path_buf[path_len * 2] = (int16_t)cx;
            path_buf[path_len * 2 + 1] = (int16_t)cy;
            path_len++;
            visited[cy * SIZE + cx] = 1;

            int fd = flow_dir[cy * SIZE + cx];
            if (fd < 0) break;
            int nx = cx + DX[fd], ny = cy + DY[fd];
            if (nx < 0 || nx >= SIZE || ny < 0 || ny >= SIZE) break;
            int nidx = ny * SIZE + nx;
            if (!mask[nidx]) break;
            if (!river[nidx]) break;
            if (visited[nidx]) {
                /* 交叉点：添加后停止 */
                path_buf[path_len * 2] = (int16_t)nx;
                path_buf[path_len * 2 + 1] = (int16_t)ny;
                path_len++;
                break;
            }
            cx = nx; cy = ny;
        }

        if (path_len < 2) continue;

        /* 写路径长度 + 路径点 */
        fwrite(&path_len, sizeof(int32_t), 1, f);
        fwrite(path_buf, sizeof(int16_t), path_len * 2, f);

        n_paths++;
        if (n_paths % 10000 == 0)
            fprintf(stderr, "  traced %d/%d paths\n", n_paths, n_sources);
    }

    /* 回写 n_paths */
    fseek(f, 0, SEEK_SET);
    fwrite(&n_paths, sizeof(int32_t), 1, f);
    fclose(f);

    fprintf(stderr, "追踪完成: %d 条路径 -> %s\n", n_paths, argv[5]);

    free(flow_dir); free(accum); free(mask);
    free(river); free(upstream); free(sources); free(visited);
    return 0;
}
