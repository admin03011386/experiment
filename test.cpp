#include <iostream>
#include <vector>
#include <queue>
#include <string>
#include <unordered_map>

using namespace std;

// 霍夫曼树节点结构体
struct MinHeapNode {
    char data;              // 存储字符
    unsigned freq;          // 存储字符出现的频率
    MinHeapNode *left, *right; // 左子节点和右子节点

    MinHeapNode(char data, unsigned freq) {
        left = right = nullptr;
        this->data = data;
        this->freq = freq;
    }
};

// 用于优先队列的比较类（构建最小堆）
struct compare {
    bool operator()(MinHeapNode* l, MinHeapNode* r) {
        return (l->freq > r->freq);
    }
};

// 打印霍夫曼编码的辅助函数
// root: 当前处理的节点
// str: 当前累积的编码字符串
void printCodes(struct MinHeapNode* root, string str) {
    if (!root)
        return;

    // 如果是叶子节点（即不是特殊的中间节点 '$'）
    if (root->data != '$')
        cout << root->data << ": " << str << "\n";

    printCodes(root->left, str + "0");
    printCodes(root->right, str + "1");
}

// 释放内存
void deleteTree(MinHeapNode* root) {
     if (!root) return;
     deleteTree(root->left);
     deleteTree(root->right);
     delete root;
}

// 构建霍夫曼树并打印编码
void HuffmanCodes(char data[], int freq[], int size) {
    struct MinHeapNode *left, *right, *top;

    // 创建一个最小优先队列，存储节点指针
    priority_queue<MinHeapNode*, vector<MinHeapNode*>, compare> minHeap;

    // 为每个字符创建叶子节点并加入优先队列
    for (int i = 0; i < size; ++i)
        minHeap.push(new MinHeapNode(data[i], freq[i]));

    // 迭代直到堆的大小为 1
    while (minHeap.size() != 1) {
        // 取出频率最小的两个节点
        left = minHeap.top();
        minHeap.pop();

        right = minHeap.top();
        minHeap.pop();

        // 创建一个新的内部节点，频率等于两个子节点频率之和
        // 使用 '$' 作为内部节点的特殊字符
        top = new MinHeapNode('$', left->freq + right->freq);

        top->left = left;
        top->right = right;

        minHeap.push(top);
    }

    // 打印霍夫曼编码
    cout << "Huffman Codes Result:\n";
    printCodes(minHeap.top(), "");
    
    // 清理内存
    deleteTree(minHeap.top());
}

int main() {
    // 示例数据
    char arr[] = { 'a', 'b', 'c', 'd', 'e', 'f' };
    int freq[] = { 5, 9, 12, 13, 16, 45 };

    int size = sizeof(arr) / sizeof(arr[0]);
    
    cout << "Characters and Frequencies:\n";
    for(int i=0; i<size; ++i) {
        cout << arr[i] << ": " << freq[i] << endl;
    }
    cout << endl;

    HuffmanCodes(arr, freq, size);

    return 0;
}
