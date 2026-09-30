module branch_ctrl_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [2:0] rob_head = 6;
    wire [15:0] current_gen;
    wire [2:0] cp_free;
    wire [7:0] cp_alloc_id;
    logic [3:0] cp_alloc_valid = 0;
    logic [4*37-1:0] cp_alloc_payload = 0;
    logic front_redirect_valid = 0;
    logic [31:0] front_redirect_pc = 32'h400;
    logic [3:0] resolve_valid = 0;
    logic [4*103-1:0] resolve_payload = 0;
    wire [3:0] train_valid, cp_release_mask;
    wire [4*66-1:0] train_payload;
    wire squash_valid, fetch_redirect_valid;
    wire [2:0] squash_tag;
    wire [1:0] restore_cp_id;
    wire [47:0] fetch_redirect_payload;
    branch_ctrl #(.ISSUE_WIDTH(4), .DISPATCH_WIDTH(4), .ROB_DEPTH(8)) dut (.*);
    task automatic allocate;
        @(negedge clock);
        cp_alloc_valid = 4'hf;
        for (int c = 0; c < 4; c = c+1)
            cp_alloc_payload[c*37 +: 37] = {2'(c), 3'(6+c), 32'(c*16+4)};
        @(negedge clock) cp_alloc_valid = 0;
    endtask
    task automatic resolve(input integer lane, input integer cp,
                           input integer tag, input [31:0] npc);
        resolve_payload[lane*103 +: 103] =
            {3'(tag), 2'(cp), 32'(cp*16), 1'b1, 1'b1, npc, npc};
    endtask
    initial begin
        repeat (2) @(negedge clock);
        reset = 0;
        allocate();
        resolve_valid = 4'hf;
        resolve(0, 3, 1, 32'h300); // young misprediction, ALU lane 0
        resolve(1, 1, 7, 20);      // old correct prediction
        resolve(2, 2, 0, 32'h200); // oldest misprediction across ROB wrap
        resolve(3, 0, 6, 4);       // oldest correct prediction
        #1;
        if (!squash_valid || squash_tag !== 0 || restore_cp_id !== 2 ||
            fetch_redirect_payload !== {32'h200, 16'd1} || cp_release_mask !== 4'hf)
            $fatal(1, "oldest misprediction or wrapped age selected incorrectly");
        if (train_valid !== 4'b0111 ||
            train_payload[0 +: 66] !== {32'd0, 1'b1, 1'b1, 32'd4} ||
            train_payload[66 +: 66] !== {32'd16, 1'b1, 1'b1, 32'd20} ||
            train_payload[132 +: 66] !== {32'd32, 1'b1, 1'b1, 32'h200})
            $fatal(1, "training not filtered and ordered by ROB age");
        @(negedge clock);
        #1;
        if (train_valid !== 0 || squash_valid || current_gen !== 1 || cp_free !== 4)
            $fatal(1, "released checkpoint trained again");
        resolve_valid = 0;
        allocate();
        // All correct predictions must train, with no generation increment.
        resolve_valid = 4'hf;
        resolve(0, 3, 1, 52);
        resolve(1, 2, 0, 36);
        resolve(2, 1, 7, 20);
        resolve(3, 0, 6, 4);
        #1;
        if (squash_valid || train_valid !== 4'hf ||
            train_payload[0 +: 66] !== {32'd0, 1'b1, 1'b1, 32'd4} ||
            train_payload[198 +: 66] !== {32'd48, 1'b1, 1'b1, 32'd52})
            $fatal(1, "correct branch training lost or out of order");
        @(negedge clock) resolve_valid = 0;
        allocate();
        resolve_valid = 1;
        resolve(0, 0, 5, 32'hbad); // stale identity must not train
        #1;
        if (train_valid !== 0 || squash_valid) $fatal(1, "stale resolve accepted");
        front_redirect_valid = 1;
        #1;
        if (fetch_redirect_payload !== {32'h400, 16'd2} || !fetch_redirect_valid || squash_valid)
            $fatal(1, "frontend correction damaged recovery semantics");
        @(negedge clock);
        front_redirect_valid = 0;
        resolve_valid = 0;
        #1;
        if (current_gen !== 2 || cp_free !== 0) $fatal(1, "frontend correction released checkpoints");
        $display("PASS branch filtering, ROB wrap, ordering and generation");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "branch control timeout");
    end
endmodule
