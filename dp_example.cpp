// 简单的动态规划入门示例（C++）
// 包含两个例子：
// 1. 斐波那契数列（自底向上 DP）
// 2. 0-1 背包问题（二维 DP）

#include <iostream>
#include <vector>
using namespace std;

// 斐波那契数列：返回 F(n)
long long fib_dp(int n) {
    if (n == 0) return 0;
    if (n == 1) return 1;

    vector<long long> dp(n + 1);
    dp[0] = 0;
    dp[1] = 1;
    for (int i = 2; i <= n; ++i) {
        dp[i] = dp[i - 1] + dp[i - 2];
    }
    return dp[n];
}

// 0-1 背包：给定物品重量和价值、背包容量 W，返回最大总价值
int knapsack_01(const vector<int>& weights, const vector<int>& values, int W) {
    int n = (int)weights.size();
    // dp[i][j] 表示只考虑前 i 个物品、容量为 j 时的最大价值
    vector<vector<int>> dp(n + 1, vector<int>(W + 1, 0));

    for (int i = 1; i <= n; ++i) {
        int w = weights[i - 1];
        int v = values[i - 1];
        for (int j = 0; j <= W; ++j) {
            // 不选第 i 个物品
            dp[i][j] = dp[i - 1][j];
            // 尝试选第 i 个物品
            if (j >= w) {
                dp[i][j] = max(dp[i][j], dp[i - 1][j - w] + v);
            }
        }
    }
    return dp[n][W];
}

int main() {
    // 示例 1：斐波那契
    int n;
    cout << "请输入 n（求 F(n)）：";
    if (!(cin >> n)) {
        cerr << "输入错误\n";
        return 1;
    }
    cout << "F(" << n << ") = " << fib_dp(n) << endl;

    // 示例 2：0-1 背包
    int itemCount, W;
    cout << "\n请输入物品数量和背包容量（例如：3 4）：";
    if (!(cin >> itemCount >> W)) {
        cerr << "输入错误\n";
        return 1;
    }

    vector<int> weights(itemCount), values(itemCount);
    cout << "依次输入每个物品的重量和价值（例如：2 4）：\n";
    for (int i = 0; i < itemCount; ++i) {
        cin >> weights[i] >> values[i];
    }

    int ans = knapsack_01(weights, values, W);
    cout << "在容量为 " << W << " 的背包中，最大总价值 = " << ans << endl;

    return 0;
}
