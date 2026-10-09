// Verify actual top-level boundaries from the first instruction return onward.
// ID/RN/DP and IS/RR are fused in the default single-issue configuration.
module pipeline_stages_test;
    logic clock=0; always #5 clock=~clock;
    logic reset=1;
    wire [31:0] araddr, awaddr, wdata;
    wire arvalid, arready, rready, awvalid, wvalid, bready;
    wire [3:0] wstrb;
    logic [31:0] rdata;
    logic rvalid=0, bvalid=0;
    logic got_aw=0, got_w=0;
    logic [31:0] aw_seen, w_seen;
    logic [3:0] strb_seen;
    integer cycle=0, return_cycle=-1;
    logic [7:0] observed=0;
    student_top #(.ISSUE_WIDTH(1),.DISPATCH_WIDTH(1),.WB_WIDTH(1),.COMMIT_WIDTH(1),
        .BP_ENABLE(0),.DCACHE_SIZE_BYTES(128)) dut(
        .clock,.reset,.araddr,.arvalid,.arready,.rdata,.rresp(2'b0),.rvalid,.rready,
        .awaddr,.awvalid,.awready(1'b1),.wdata,.wstrb,.wvalid,.wready(1'b1),
        .bresp(2'b0),.bvalid,.bready);
    assign arready=!rvalid;
    function automatic [31:0] word_at(input [31:0] addr);
        case(addr)
            0: word_at=32'h02a00513; // addi x10,x0,42 (independent)
            4: word_at=32'h800002b7; // lui x5,0x80000
            8: word_at=32'h00a2a023; // sw x10,0(x5)
            default: word_at=32'h00000013;
        endcase
    endfunction
    task automatic expect_stage(input integer offset, input integer bit_no);
        if(cycle!=return_cycle+offset) $fatal(1,"stage %0d appeared at %0d, expected %0d",bit_no,cycle,return_cycle+offset);
        if(observed[bit_no]) $fatal(1,"stage %0d repeated",bit_no);
        observed[bit_no]=1;
    endtask
    always @(posedge clock) begin
        if(!reset) begin
            cycle=cycle+1;
            if(dut.ic_rsp_valid && dut.ic_rsp_payload[32 +:1]==1 &&
                dut.ic_rsp_payload[33 +:4]==0 && return_cycle<0) return_cycle=cycle;
            if(return_cycle>=0) begin
                if(dut.fetch_valid && dut.fetch_ready && dut.fetch_packet[95:64]==0) expect_stage(0,0); // ID
                if(dut.decode_valid && dut.decode_ready && dut.decode_uop[116:85]==0) expect_stage(0,1); // RN
                if(dut.disp_fire && dut.disp_alu[63:32]==0) expect_stage(0,2); // DP
                if(dut.alu_cand_take[0] && dut.alu_cand_uop[63:32]==0) expect_stage(1,3); // IS
                if(dut.alu_cand_take[0] && dut.alu_cand_uop[63:32]==0) expect_stage(1,4); // RR
                if(dut.alu_exec_valid[0] && dut.alu_exec_ready[0] && dut.alu_exec_payload[127:96]==0) expect_stage(2,5); // EX
                if(dut.done_valid[0] && dut.done_tag==0) begin
                    expect_stage(3,6); // WB
                    if(!dut.write_valid[0] || dut.write_value!=42) $fatal(1,"WB value mismatch");
                end
                if(cycle==return_cycle+4) begin // CM
                    if(dut.rob_head!=0 || !dut.reg_commit_valid[0]) $fatal(1,"ROB retired before/after CM");
                    expect_stage(4,7);
                end
            end
            if(rvalid && rready) rvalid<=0;
            if(arvalid && arready) begin rvalid<=1; rdata<=word_at(araddr); end
            if(awvalid) begin got_aw<=1; aw_seen<=awaddr; end
            if(wvalid) begin got_w<=1; w_seen<=wdata; strb_seen<=wstrb; end
            if(got_aw && got_w && !bvalid) bvalid<=1;
            if(bvalid && bready) begin
                if(observed!=8'hff || aw_seen!==32'h80000000 || w_seen!==42 || strb_seen!==4'hf)
                    $fatal(1,"pipeline or exit incorrect: stages=%h addr=%h data=%h strb=%h",observed,aw_seen,w_seen,strb_seen);
                $display("PASS fused single-issue boundaries: return through commit and dependent Store");
                $finish;
            end
        end
    end
    initial begin
        repeat(3) @(negedge clock); reset=0;
        repeat(500) @(posedge clock); $fatal(1,"pipeline test timeout");
    end
endmodule
