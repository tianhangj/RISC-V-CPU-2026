module fetch_prediction_case #(
    parameter integer D = 2,
    parameter integer OUTSTANDING = 8,
    parameter integer FIRST_BRANCH = 4
) (output logic done);
    localparam integer DCW = $clog2(D+1);
    localparam integer REQ_BITS = 16+4+DCW+32;
    localparam integer RSP_BITS = 16+4+DCW+D*32;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, predictor_reset = 1, redirect = 0;
    logic [47:0] redirect_payload = 0;
    wire [31:0] lookup_pc;
    wire [D-1:0] pred_taken;
    wire [D*32-1:0] pred_npc;
    logic train_valid = 0;
    logic [65:0] train_payload = 0;
    wire ic_req_valid, ic_rsp_valid, fetch_valid;
    wire [REQ_BITS-1:0] ic_req_payload;
    logic [RSP_BITS-1:0] ic_rsp_payload;
    wire [DCW-1:0] fetch_count;
    wire [D*96-1:0] fetch_packet;
    integer cycles = 0, qhead = 0, qtail = 0, qcount = 0;
    logic [REQ_BITS-1:0] queue [0:31];
    integer due [0:31];
    integer received = 0, phase = 0, credits = 0;
    logic [31:0] expected_pc = 0, expected_req_pc = 0;
    wire ic_req_ready = qcount < 16 && cycles % 7 != 2;
    wire fetch_ready = phase != 1 && cycles % 11 < 8;
    assign ic_rsp_valid = qcount != 0 && cycles >= due[qhead];
    logic out_stalled = 0, req_stalled = 0;
    logic [D*96+DCW-1:0] saved_output;
    logic [REQ_BITS-1:0] saved_req;
    function automatic [31:0] predicted_npc(input [31:0] pc);
        case (pc)
            FIRST_BRANCH: predicted_npc = 28;
            28: predicted_npc = 64;
            64: predicted_npc = 68; // taken with target == fall-through
            68: predicted_npc = 68; // self-loop
            default: predicted_npc = pc+32'd4;
        endcase
    endfunction
    function automatic logic predicted_taken(input [31:0] pc);
        predicted_taken = pc == FIRST_BRANCH || pc == 28 || pc == 64 || pc == 68;
    endfunction
    always_comb begin
        ic_rsp_payload = 0;
        ic_rsp_payload[D*32 +: 16+4+DCW] = queue[qhead][32 +: 16+4+DCW];
        for (int lane = 0; lane < D; lane = lane+1)
            ic_rsp_payload[lane*32 +: 32] =
                (queue[qhead][31:0]+32'(lane*4)) ^ 32'hbadc0013;
    end
    branch_predictor #(.DISPATCH_WIDTH(D), .ISSUE_WIDTH(1)) predictor (
        .clock, .reset(predictor_reset), .lookup_pc, .pred_taken, .pred_npc,
        .train_valid, .train_payload);
    fetch #(.DISPATCH_WIDTH(D), .IFETCH_OUTSTANDING(OUTSTANDING)) dut (
        .clock, .reset, .fetch_redirect_valid(redirect), .fetch_redirect_payload(redirect_payload),
        .lookup_pc, .pred_taken, .pred_npc,
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet);
    always @(posedge clock) begin
        cycles <= cycles+1;
        if (cycles > 2000) $fatal(1, "fetch prediction timeout D=%0d", D);
        if (ic_req_valid && ic_req_ready) begin
            queue[qtail] <= ic_req_payload;
            due[qtail] <= cycles+4;
            qtail <= (qtail+1)%32;
        end
        if (ic_rsp_valid) qhead <= (qhead+1)%32;
        qcount <= qcount+int'(ic_req_valid && ic_req_ready)-int'(ic_rsp_valid);
        if (!reset) begin
            if (redirect) begin
                credits = 0;
                expected_pc = redirect_payload[47:16];
                expected_req_pc = expected_pc;
                received = 0;
                out_stalled <= 0;
                req_stalled <= 0;
            end else begin
                if (out_stalled && (!fetch_valid || {fetch_count, fetch_packet} !== saved_output))
                    $fatal(1, "prediction update changed stalled output D=%0d", D);
                if (req_stalled && (!ic_req_valid || ic_req_payload !== saved_req))
                    $fatal(1, "prediction update changed stalled request D=%0d", D);
                out_stalled <= fetch_valid && !fetch_ready;
                req_stalled <= ic_req_valid && !ic_req_ready;
                saved_output <= {fetch_count, fetch_packet};
                saved_req <= ic_req_payload;
                if (ic_req_valid && ic_req_ready) begin
                    if (ic_req_payload[32 +: DCW] == 0 ||
                        int'(ic_req_payload[32 +: DCW])+int'(ic_req_payload[4:2]) > 8)
                        $fatal(1, "predicted request crossed cache line");
                    credits = credits+int'(ic_req_payload[32 +: DCW]);
                    if (phase != 1) begin
                        if (ic_req_payload[31:0] !== expected_req_pc)
                            $fatal(1, "request followed wrong path D=%0d got=%h expected=%h",
                                D, ic_req_payload[31:0], expected_req_pc);
                        for (int lane = 0; lane < D; lane = lane+1)
                            if (lane < ic_req_payload[32 +: DCW]) begin
                                if (phase == 0 && predicted_taken(expected_req_pc) &&
                                    lane != int'(ic_req_payload[32 +: DCW])-1)
                                    $fatal(1, "request not truncated at first predicted jump");
                                expected_req_pc = phase == 0 ? predicted_npc(expected_req_pc) :
                                    expected_req_pc+32'd4;
                            end
                    end
                end
                if (ic_rsp_valid && ic_rsp_payload[D*32+DCW+4 +: 16] == dut.fetch_gen)
                    credits = credits-int'(ic_rsp_payload[D*32 +: DCW]);
                if (credits < 0 || credits > OUTSTANDING) $fatal(1, "prediction credit accounting error");
                if (fetch_valid && fetch_ready) begin
                    for (int lane = 0; lane < D; lane = lane+1)
                        if (lane < fetch_count) begin
                            if (fetch_packet[lane*96+64 +: 32] !== expected_pc ||
                                fetch_packet[lane*96+32 +: 32] !== (expected_pc ^ 32'hbadc0013) ||
                                fetch_packet[lane*96 +: 32] !==
                                    (phase == 0 ? predicted_npc(expected_pc) : expected_pc+32'd4))
                                $fatal(1, "predicted packet corrupt D=%0d pc=%h", D, expected_pc);
                            if (phase == 0 && predicted_taken(expected_pc) && lane != int'(fetch_count)-1)
                                $fatal(1, "output combined paths across predicted jump");
                            expected_pc = phase == 0 ? predicted_npc(expected_pc) : expected_pc+32'd4;
                            received = received+1;
                        end
                end
            end
        end
    end
    task automatic train(input [31:0] pc, input logic conditional, input [31:0] target);
        @(negedge clock);
        train_valid = 1;
        train_payload = {pc, conditional, 1'b1, target};
        @(negedge clock) train_valid = 0;
    endtask
    initial begin
        done = 0;
        repeat (2) @(negedge clock);
        predictor_reset = 0;
        train(32'(FIRST_BRANCH), 0, 28);
        train(28, 1, 64);
        train(64, 0, 68);
        train(68, 0, 68);
        @(negedge clock) reset = 0;
        wait (received >= 30);
        @(negedge clock) phase = 1;
        wait (fetch_valid);
        // Change the prediction for the buffered branch while its output is stalled.
        train(fetch_packet[95:64], 0, 100);
        repeat (8) @(negedge clock);
        redirect = 1;
        redirect_payload = {32'h100, 16'd1};
        @(negedge clock);
        redirect = 0;
        phase = 2;
        wait (received >= 12);
        @(negedge clock);
        $display("PASS predicted fetch D=%0d credits=%0d first_branch=%0d", D, OUTSTANDING, FIRST_BRANCH);
        done = 1;
    end
endmodule
module fetch_prediction_test;
    wire [6:0] done;
    fetch_prediction_case #(.D(1)) c0(done[0]);
    fetch_prediction_case #(.D(2)) c1(done[1]);
    fetch_prediction_case #(.D(4)) c2(done[2]);
    fetch_prediction_case #(.D(4), .OUTSTANDING(1)) c3(done[3]);
    fetch_prediction_case #(.D(4), .FIRST_BRANCH(0)) c4(done[4]);
    fetch_prediction_case #(.D(4), .FIRST_BRANCH(8)) c5(done[5]);
    fetch_prediction_case #(.D(4), .FIRST_BRANCH(12)) c6(done[6]);
    initial begin
        wait (&done);
        $finish;
    end
endmodule
