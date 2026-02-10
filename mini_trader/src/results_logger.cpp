#include <iostream>
#include <fstream>
#include <vector>
#include <string>

void log_results(const std::vector<int>& orders, const std::string& out_csv) {
    std::ofstream fout(out_csv);
    fout << "symbol_id,order\n";
    for (size_t i = 0; i < orders.size(); ++i) {
        fout << i << "," << orders[i] << "\n";
    }
    fout.close();
    std::cout << "Results written to " << out_csv << "\n";
}

int main(int argc, char** argv) {
    std::vector<int> orders = {1,0,1,0,0,1,1,0,0,1};
    std::string out_csv = (argc > 1) ? argv[1] : "orders.csv";
    log_results(orders, out_csv);
    return 0;
}
