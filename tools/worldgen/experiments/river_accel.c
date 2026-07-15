/* river_accel.c - 河流生成 C 加速器
 *
 * 功能：
 *   1. Priority-Flood 填洼（Wang & Liu 2006）+ D8 流向
 *   2. 单位降雨流量累积（Kahn 拓扑排序）
 *   3. 基于流量累积的海岸出口选择（最大最小距离）
 *   4. 反向 BFS 流域分割
 *   5. 未分配格子扩散填充
 *
 * 编译: gcc -O3 -ffast-math -march=native -o river_accel.exe river_accel.c -lm
 * 运行: river_accel.exe <heightmap.bin> <mask.bin> <flow_dir.bin> <watershed.bin>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#define SIZE 8192
#define TOTAL (SIZE * SIZE)

/* D8 方向: 0=N(0,-1) 1=NE(1,-1) 2=E(1,0) 3=SE(1,1)
 *          4=S(0,1)  5=SW(-1,1) 6=W(-1,0) 7=NW(-1,-1) */
static const int DX[8] = {0, 1, 1, 1, 0, -1, -1, -1};
static const int DY[8] = {-1, -1, 0, 1, 1, 1, 0, -1};

/* ==================== 最小堆 ==================== */
typedef struct { float e; int i; } HN;
static HN *hd;
static int hs;

static void hinit(int cap) {
    hd = (HN*)malloc(sizeof(HN) * cap);
    hs = 0;
}

static void hpush(float e, int i) {
    int c = hs++;
    while (c > 0) {
        int p = (c - 1) >> 1;
        if (hd[p].e <= e) break;
        hd[c] = hd[p];
        c = p;
    }
    hd[c].e = e;
    hd[c].i = i;
}

static int hpop(void) {
    int top = hd[0].i;
    HN last = hd[--hs];
    int c = 0;
    while (1) {
        int a = (c << 1) + 1, b = a + 1, s = c;
        if (a < hs && hd[a].e < last.e) s = a;
        if (b < hs && hd[b].e < (s == a ? hd[a].e : last.e)) s = b;
        if (s == c) break;
        hd[c] = hd[s];
        c = s;
    }
    hd[c] = last;
    return top;
}

/* ==================== FIFO 队列 ==================== */
static int *fifo_data;
static int fifo_head, fifo_tail;

static void fifo_init(int cap) {
    fifo_data = (int*)malloc(sizeof(int) * cap);
    fifo_head = fifo_tail = 0;
}
static void fifo_push(int v) { fifo_data[fifo_tail++] = v; }
static int fifo_pop(void) { return fifo_data[fifo_head++]; }
static int fifo_empty(void) { return fifo_head == fifo_tail; }

/* ==================== 主函数 ==================== */
int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "用法: %s <heightmap.bin> <mask.bin> <flow_dir.bin> <watershed.bin>\n", argv[0]);
        return 1;
    }

    /* ---------- 分配内存 ---------- */
    float   *elev     = (float*)malloc(sizeof(float)   * TOTAL);
    uint8_t *mask     = (uint8_t*)malloc(sizeof(uint8_t) * TOTAL);
    int8_t  *flow_dir = (int8_t*)malloc(sizeof(int8_t)  * TOTAL);
    int32_t *ws       = (int32_t*)malloc(sizeof(int32_t) * TOTAL);

    if (!elev || !mask || !flow_dir || !ws) {
        fprintf(stderr, "内存分配失败\n");
        return 2;
    }

    /* ---------- 加载数据 ---------- */
    FILE *f;
    f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "无法打开 %s\n", argv[1]); return 3; }
    fread(elev, sizeof(float), TOTAL, f);
    fclose(f);

    f = fopen(argv[2], "rb");
    if (!f) { fprintf(stderr, "无法打开 %s\n", argv[2]); return 3; }
    fread(mask, sizeof(uint8_t), TOTAL, f);
    fclose(f);

    memset(flow_dir, -1, sizeof(int8_t) * TOTAL);
    for (int i = 0; i < TOTAL; i++) ws[i] = -1;

    /* 海洋格高度设为极低值 */
    int n_ocean = 0, n_land = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (!mask[i]) {
            elev[i] = -1e30f;
            n_ocean++;
        } else {
            n_land++;
        }
    }
    fprintf(stderr, "数据加载: 海洋 %d (%.1f%%), 陆地 %d (%.1f%%)\n",
            n_ocean, 100.0*n_ocean/TOTAL, n_land, 100.0*n_land/TOTAL);

    /* ---------- 1. Priority-Flood 填洼 + D8 流向 ---------- */
    uint8_t *closed = (uint8_t*)calloc(TOTAL, sizeof(uint8_t));
    hinit(TOTAL);

    for (int i = 0; i < TOTAL; i++) {
        if (!mask[i]) {
            hpush(elev[i], i);
            closed[i] = 1;
            flow_dir[i] = -2;
        }
    }
    fprintf(stderr, "海洋格入队: %d\n", hs);

    long processed = 0;
    while (hs > 0) {
        int idx = hpop();
        float cur = elev[idx];
        int cx = idx % SIZE, cy = idx / SIZE;

        for (int d = 0; d < 8; d++) {
            int nx = cx + DX[d], ny = cy + DY[d];
            if (nx < 0 || nx >= SIZE || ny < 0 || ny >= SIZE) continue;
            int nidx = ny * SIZE + nx;
            if (closed[nidx]) continue;

            if (elev[nidx] < cur) elev[nidx] = cur;
            flow_dir[nidx] = (int8_t)((d + 4) % 8);
            closed[nidx] = 1;
            hpush(elev[nidx], nidx);
        }

        processed++;
        if (processed % 10000000 == 0)
            fprintf(stderr, "  PF %ld/%d (%.1f%%) heap=%d\n", processed, TOTAL, 100.0*processed/TOTAL, hs);
    }
    free(closed);
    free(hd);
    fprintf(stderr, "Priority-Flood + D8 完成 (处理 %ld 格)\n", processed);

    /* ---------- 2. 单位降雨流量累积（Kahn 拓扑排序）---------- */
    /* 每格初始流量 = 1.0（单位降雨），沿流向累加到下游 */
    float *accum = (float*)calloc(TOTAL, sizeof(float));
    int16_t *in_degree = (int16_t*)calloc(TOTAL, sizeof(int16_t));

    /* 计算入度（有多少上游格子指向当前格子） */
    for (int i = 0; i < TOTAL; i++) {
        if (!mask[i]) continue;
        int fd = flow_dir[i];
        if (fd < 0) continue;
        int x = i % SIZE, y = i / SIZE;
        int dx = DX[fd], dy = DY[fd];
        int down = (y + dy) * SIZE + (x + dx);
        if (down >= 0 && down < TOTAL) {
            in_degree[down]++;
        }
    }

    /* 初始化流量 = 1.0，源头格子（入度=0）入队 */
    fifo_init(TOTAL);
    for (int i = 0; i < TOTAL; i++) {
        if (!mask[i]) continue;
        accum[i] = 1.0f;
        if (in_degree[i] == 0) {
            fifo_push(i);
        }
    }
    fprintf(stderr, "源头格子入队: %d\n", fifo_tail - fifo_head);

    /* Kahn 拓扑排序 */
    long accum_processed = 0;
    while (!fifo_empty()) {
        int idx = fifo_pop();
        int fd = flow_dir[idx];
        if (fd < 0) continue;

        int x = idx % SIZE, y = idx / SIZE;
        int down = (y + DY[fd]) * SIZE + (x + DX[fd]);
        if (down < 0 || down >= TOTAL) continue;

        /* 累加流量到下游 */
        accum[down] += accum[idx];

        /* 如果下游是陆地，减少入度 */
        if (mask[down]) {
            in_degree[down]--;
            if (in_degree[down] == 0) {
                fifo_push(down);
            }
        }

        accum_processed++;
        if (accum_processed % 10000000 == 0)
            fprintf(stderr, "  accum %ld/%d\n", accum_processed, n_land);
    }
    free(in_degree);
    free(fifo_data);
    fprintf(stderr, "流量累积完成 (处理 %ld 格)\n", accum_processed);

    /* ---------- 3. 海岸出口选择 ---------- */
    /* 海岸格 = 陆地且 4连通邻居有海洋 */
    /* 候选出口 = 流量累积 > 阈值的海岸格 */
    uint8_t *is_coast = (uint8_t*)calloc(TOTAL, sizeof(uint8_t));
    int n_coast = 0;

    /* 收集海岸格及其流量累积 */
    typedef struct { int idx; float accum; } CoastCell;
    CoastCell *coast_cells = (CoastCell*)malloc(sizeof(CoastCell) * TOTAL);
    float accum_threshold = 0;

    for (int y = 0; y < SIZE; y++) {
        for (int x = 0; x < SIZE; x++) {
            int idx = y * SIZE + x;
            if (!mask[idx]) continue;
            int coast = 0;
            if (x > 0 && !mask[idx-1]) coast = 1;
            if (x < SIZE-1 && !mask[idx+1]) coast = 1;
            if (y > 0 && !mask[idx-SIZE]) coast = 1;
            if (y < SIZE-1 && !mask[idx+SIZE]) coast = 1;
            if (!coast) continue;

            is_coast[idx] = 1;
            coast_cells[n_coast].idx = idx;
            coast_cells[n_coast].accum = accum[idx];
            n_coast++;
        }
    }
    fprintf(stderr, "海岸格数量: %d\n", n_coast);

    /* 按流量累积降序排序海岸格（简单选择排序 top-K） */
    /* 取 top-200 候选 */
    int n_candidates = n_coast < 200 ? n_coast : 200;
    for (int i = 0; i < n_candidates; i++) {
        int best = i;
        for (int j = i + 1; j < n_coast; j++) {
            if (coast_cells[j].accum > coast_cells[best].accum)
                best = j;
        }
        if (best != i) {
            CoastCell t = coast_cells[i]; coast_cells[i] = coast_cells[best]; coast_cells[best] = t;
        }
    }

    /* 打印 top-10 流量累积 */
    fprintf(stderr, "海岸格流量累积 top-10:\n");
    for (int i = 0; i < 10 && i < n_coast; i++) {
        int idx = coast_cells[i].idx;
        fprintf(stderr, "  #%d: idx=%d (%d,%d) accum=%.0f\n", i, idx, idx%SIZE, idx/SIZE, coast_cells[i].accum);
    }

    /* 最大最小距离选 N 个出口 */
    /* N = 陆地面积 / 目标流域面积，目标流域面积 = 200万像素 */
    int target_n = n_land / 2000000;
    if (target_n < 8) target_n = 8;
    if (target_n > 30) target_n = 30;
    if (target_n > n_candidates) target_n = n_candidates;
    fprintf(stderr, "目标出口数: %d (陆地 %d / 2000000)\n", target_n, n_land);

    /* 最大最小距离选择 */
    int *outlets = (int*)malloc(sizeof(int) * target_n);
    int n_outlets = 0;
    uint8_t *selected = (uint8_t*)calloc(n_coast, sizeof(uint8_t));

    /* 第一个出口：流量累积最大 */
    outlets[0] = coast_cells[0].idx;
    selected[0] = 1;
    n_outlets = 1;

    /* 后续出口：最大最小距离 */
    while (n_outlets < target_n) {
        float best_min_dist = -1;
        int best_candidate = -1;

        for (int i = 0; i < n_candidates; i++) {
            if (selected[i]) continue;
            int cx = coast_cells[i].idx % SIZE, cy = coast_cells[i].idx / SIZE;

            float min_dist = 1e30f;
            for (int j = 0; j < n_outlets; j++) {
                int ox = outlets[j] % SIZE, oy = outlets[j] / SIZE;
                float dx = cx - ox, dy = cy - oy;
                float dist = dx*dx + dy*dy;
                if (dist < min_dist) min_dist = dist;
            }

            /* 综合距离和流量累积：优先选远的且流量大的 */
            /* 简单策略：纯最大最小距离 */
            if (min_dist > best_min_dist) {
                best_min_dist = min_dist;
                best_candidate = i;
            }
        }

        if (best_candidate < 0) break;
        outlets[n_outlets] = coast_cells[best_candidate].idx;
        selected[best_candidate] = 1;
        n_outlets++;
    }

    fprintf(stderr, "选定 %d 个出口:\n", n_outlets);
    for (int i = 0; i < n_outlets; i++) {
        int idx = outlets[i];
        fprintf(stderr, "  出口 %d: (%d,%d) accum=%.0f\n", i, idx%SIZE, idx/SIZE, accum[idx]);
    }

    free(selected);
    free(coast_cells);

    /* ---------- 4. 反向 BFS 流域分割 ---------- */
    /* 从选定的出口开始，沿 flow_dir 反方向传播流域 ID */
    fifo_init(TOTAL);

    /* 出口格设置流域 ID */
    for (int i = 0; i < n_outlets; i++) {
        ws[outlets[i]] = i;
        fifo_push(outlets[i]);
    }
    fprintf(stderr, "出口入队: %d\n", n_outlets);

    while (!fifo_empty()) {
        int idx = fifo_pop();
        int cx = idx % SIZE, cy = idx / SIZE;
        int w = ws[idx];

        for (int d = 0; d < 8; d++) {
            int nx = cx + DX[d], ny = cy + DY[d];
            if (nx < 0 || nx >= SIZE || ny < 0 || ny >= SIZE) continue;
            int nidx = ny * SIZE + nx;
            if (!mask[nidx]) continue;
            if (ws[nidx] != -1) continue;

            /* 检查 n 的 flow_dir 是否指向 idx */
            int fd = flow_dir[nidx];
            if (fd < 0) continue;
            int down = (ny + DY[fd]) * SIZE + (nx + DX[fd]);
            if (down == idx) {
                ws[nidx] = w;
                fifo_push(nidx);
            }
        }
    }
    free(fifo_data);
    fprintf(stderr, "反向 BFS 流域分割完成\n");

    /* ---------- 5a. 扩散填充未分配格子（主大陆） ---------- */
    int unassigned = 0;
    for (int i = 0; i < TOTAL; i++) {
        if (mask[i] && ws[i] == -1) unassigned++;
    }
    fprintf(stderr, "未分配陆地格子: %d\n", unassigned);

    if (unassigned > 0) {
        fifo_init(TOTAL);
        for (int i = 0; i < TOTAL; i++) {
            if (mask[i] && ws[i] >= 0) fifo_push(i);
        }
        while (!fifo_empty()) {
            int idx = fifo_pop();
            int cx = idx % SIZE, cy = idx / SIZE;
            int w = ws[idx];
            for (int d = 0; d < 8; d++) {
                int nx = cx + DX[d], ny = cy + DY[d];
                if (nx < 0 || nx >= SIZE || ny < 0 || ny >= SIZE) continue;
                int nidx = ny * SIZE + nx;
                if (!mask[nidx] || ws[nidx] != -1) continue;
                ws[nidx] = w;
                fifo_push(nidx);
            }
        }
        free(fifo_data);

        int still = 0;
        for (int i = 0; i < TOTAL; i++)
            if (mask[i] && ws[i] == -1) still++;
        fprintf(stderr, "扩散填充后仍未分配: %d\n", still);
    }

    /* ---------- 5b. 孤立岛屿：每个岛屿创建独立流域 ---------- */
    /* 扩散填充后仍未分配的格子 = 不与主大陆8连通的岛屿 */
    /* 每个岛屿找最高流量海岸格作为出口，创建新流域ID */
    {
        int n_islands = 0;
        fifo_init(TOTAL);
        for (int seed = 0; seed < TOTAL; seed++) {
            if (!mask[seed] || ws[seed] != -1) continue;

            /* 找到岛屿的种子点，BFS收集所有连通的未分配格子 */
            int island_label = n_outlets; /* 新流域ID */
            fifo_head = fifo_tail = 0;
            fifo_push(seed);
            ws[seed] = island_label;
            int island_size = 1;

            /* 同时找岛屿内流量最大的海岸格 */
            int best_coast = -1;
            float best_accum = -1.0f;

            if (is_coast[seed] && accum[seed] > best_accum) {
                best_accum = accum[seed];
                best_coast = seed;
            }

            while (!fifo_empty()) {
                int idx = fifo_pop();
                int cx = idx % SIZE, cy = idx / SIZE;
                for (int d = 0; d < 8; d++) {
                    int nx = cx + DX[d], ny = cy + DY[d];
                    if (nx < 0 || nx >= SIZE || ny < 0 || ny >= SIZE) continue;
                    int nidx = ny * SIZE + nx;
                    if (!mask[nidx] || ws[nidx] != -1) continue;
                    ws[nidx] = island_label;
                    fifo_push(nidx);
                    island_size++;

                    if (is_coast[nidx] && accum[nidx] > best_accum) {
                        best_accum = accum[nidx];
                        best_coast = nidx;
                    }
                }
            }

            /* 重新从该岛屿的最佳海岸格做反向BFS，让流域分割更自然 */
            /* 但先简单处理：整个岛屿归为新流域 */
            n_outlets++;
            n_islands++;

            if (island_size > 100) {
                fprintf(stderr, "  岛屿 %d: 大小=%d, 最佳出口accum=%.0f\n",
                        n_islands, island_size, best_accum);
            }
        }
        free(fifo_data);
        fprintf(stderr, "孤立岛屿流域: %d 个, 总流域数: %d\n", n_islands, n_outlets);
    }

    /* ---------- 6. 统计 + 输出 ---------- */
    int *ws_count = (int*)calloc(n_outlets, sizeof(int));
    for (int i = 0; i < TOTAL; i++) {
        if (mask[i] && ws[i] >= 0 && ws[i] < n_outlets)
            ws_count[ws[i]]++;
    }
    fprintf(stderr, "\n=== 流域统计 ===\n");
    fprintf(stderr, "出口数: %d\n", n_outlets);
    int total_assigned = 0;
    for (int i = 0; i < n_outlets; i++) {
        total_assigned += ws_count[i];
        fprintf(stderr, "  流域 %d: %d 格 (%.2f%%)\n", i, ws_count[i], 100.0*ws_count[i]/TOTAL);
    }
    fprintf(stderr, "总分配陆地: %d / %d (%.1f%%)\n", total_assigned, n_land, 100.0*total_assigned/n_land);

    /* 输出 flow_dir */
    f = fopen(argv[3], "wb");
    fwrite(flow_dir, sizeof(int8_t), TOTAL, f);
    fclose(f);
    fprintf(stderr, "flow_dir -> %s\n", argv[3]);

    /* 输出 watershed */
    f = fopen(argv[4], "wb");
    fwrite(ws, sizeof(int32_t), TOTAL, f);
    fclose(f);
    fprintf(stderr, "watershed -> %s\n", argv[4]);

    /* 清理 */
    free(elev); free(mask); free(flow_dir); free(ws);
    free(accum); free(is_coast); free(outlets); free(ws_count);
    fprintf(stderr, "完成。\n");
    return 0;
}
