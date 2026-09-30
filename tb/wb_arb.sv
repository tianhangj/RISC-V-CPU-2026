module wb_arb_case #(
    parameter integer WIDTH = 1
) (output logic done);
    localparam integer SOURCES = WIDTH+2;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0;
    logic [4:0] squash_tag = 0, rob_head = 0;
    logic [WIDTH-1:0] alu_result_valid = 0;
    wire [WIDTH-1:0] alu_result_ready;
    logic [WIDTH*43-1:0] alu_result_payload = 0;
    logic mul_result_valid = 0, lsu_result_valid = 0;
    wire mul_result_ready, lsu_result_ready;
    logic [42:0] mul_result_payload = 0, lsu_result_payload = 0;
    wire [WIDTH-1:0] done_valid, write_valid;
    wire [WIDTH*5-1:0] done_tag;
    wire [WIDTH*6-1:0] write_pdst;
    wire [WIDTH*32-1:0] write_value;
    logic [SOURCES-1:0] valid_mask, eligible, selected, expected_ready;
    logic [42:0] payload [0:SOURCES-1];
    integer ref_cursor = 0, pick, index, boundary, age;
    wb_arb #(.ISSUE_WIDTH(WIDTH), .WB_WIDTH(WIDTH)) dut (.*);
    initial begin
        done = 0;
        repeat (2) @(negedge clock);
        reset = 0;
        // Every valid-mask combination, different cursor positions, all wrapped
        // ROB ages, and squash boundaries; compare against a modulo-based model.
        for (int iteration = 0; iteration < 1024; iteration = iteration+1) begin
            valid_mask = SOURCES'(iteration);
            rob_head = 5'(iteration);
            boundary = (iteration >> 3) % 8;
            squash_tag = 5'(int'(rob_head)+boundary);
            squash_valid = (iteration & 64) != 0;
            eligible = 0;
            expected_ready = 0;
            for (int source = 0; source < SOURCES; source = source+1) begin
                age = (source*7+iteration)%32;
                payload[source] = {5'(int'(rob_head)+age),
                    6'(((source+iteration)%7 == 0) ? 0 : 33+source),
                    (32'hc0de0000+32'(source))};
                eligible[source] = valid_mask[source] && (!squash_valid || age <= boundary);
                expected_ready[source] = valid_mask[source] && !eligible[source];
            end
            alu_result_valid = valid_mask[WIDTH-1:0];
            for (int source = 0; source < WIDTH; source = source+1)
                alu_result_payload[source*43 +: 43] = payload[source];
            mul_result_valid = valid_mask[WIDTH];
            lsu_result_valid = valid_mask[WIDTH+1];
            mul_result_payload = payload[WIDTH];
            lsu_result_payload = payload[WIDTH+1];
            #1;
            selected = 0;
            for (int lane = 0; lane < WIDTH; lane = lane+1) begin
                pick = -1;
                for (int offset = 0; offset < SOURCES; offset = offset+1) begin
                    index = (ref_cursor+offset)%SOURCES;
                    if (pick < 0 && eligible[index] && !selected[index]) pick = index;
                end
                if (pick >= 0) begin
                    if (!done_valid[lane] || done_tag[lane*5 +: 5] !== payload[pick][42:38] ||
                        write_valid[lane] !== (payload[pick][37:32] != 0) ||
                        write_pdst[lane*6 +: 6] !== payload[pick][37:32] ||
                        write_value[lane*32 +: 32] !== payload[pick][31:0])
                        $fatal(1, "WB round-robin result mismatch width=%0d iteration=%0d", WIDTH, iteration);
                    selected[pick] = 1;
                    expected_ready[pick] = 1;
                    ref_cursor = (pick+1)%SOURCES;
                end else if (done_valid[lane] || write_valid[lane])
                    $fatal(1, "WB emitted an ineligible result");
            end
            if ({lsu_result_ready, mul_result_ready, alu_result_ready} !== expected_ready)
                $fatal(1, "WB did not accept selected/discarded sources width=%0d", WIDTH);
            @(negedge clock);
        end
        $display("PASS WB round robin, squash and wrap WIDTH=%0d", WIDTH);
        done = 1;
    end
endmodule
module wb_arb_test;
    wire [2:0] done;
    wb_arb_case #(.WIDTH(1)) c0(done[0]);
    wb_arb_case #(.WIDTH(2)) c1(done[1]);
    wb_arb_case #(.WIDTH(4)) c2(done[2]);
    initial begin
        wait (&done);
        $finish;
    end
    initial begin
        #50000;
        $fatal(1, "WB arbitration timeout");
    end
endmodule
