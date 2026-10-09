module alu_shared_test #(parameter integer ISOLATE=0);
    reg clock=0; always #5 clock=~clock;
    reg reset=1, exec_valid=0;
    reg [146:0] exec_payload=0;
    wire exec_ready, result_valid, resolve_valid;
    wire [42:0] result_payload;
    wire [104:0] resolve_payload;
    reg [31:0] a,b,imm,pc,expected,target,npc;
    reg taken, control_flow;
    reg [31:0] random_state=32'hf019ace1;
    alu #(.BRANCH_ISOLATE(ISOLATE)) dut (.clock, .reset, .squash_valid(1'b0), .squash_tag(5'd0), .rob_head(5'd0),
        .exec_valid, .resolve_exec_valid(1'b0), .branch_operand1(a), .branch_operand2(b), .exec_ready, .exec_payload, .result_valid, .result_ready(1'b1),
        .result_payload, .resolve_valid, .resolve_payload);
    initial begin
        @(posedge clock); @(negedge clock); reset=0;
        for (integer n=0; n<96; n=n+1) begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            a=(n<32)?(32'h80000001<<n):random_state;
            b=(n<32)?32'(n):(random_state^32'hffff5555);
            imm=(n<32)?(32'hffffff00|32'(n)):~random_state;
            pc=random_state & 32'hfffffffc;
            for (integer op=1; op<=29; op=op+1) begin
                expected=0; target=pc+imm; npc=pc+4; taken=0; control_flow=0;
                case (op)
                    1: expected=imm;
                    2: expected=pc+imm;
                    3: begin control_flow=1; taken=1; expected=pc+4; end
                    4: begin control_flow=1; taken=1; expected=pc+4; target=(a+imm)&32'hfffffffe; end
                    5: begin control_flow=1; taken=a==b; end
                    6: begin control_flow=1; taken=a!=b; end
                    7: begin control_flow=1; taken=$signed(a)<$signed(b); end
                    8: begin control_flow=1; taken=$signed(a)>=$signed(b); end
                    9: begin control_flow=1; taken=a<b; end
                    10: begin control_flow=1; taken=a>=b; end
                    11: expected=a+imm;
                    12: expected=32'($signed(a)<$signed(imm));
                    13: expected=32'(a<imm);
                    14: expected=a^imm;
                    15: expected=a|imm;
                    16: expected=a&imm;
                    17: expected=a<<imm[4:0];
                    18: expected=a>>imm[4:0];
                    19: expected=$signed(a)>>>imm[4:0];
                    20: expected=a+b;
                    21: expected=a-b;
                    22: expected=a<<b[4:0];
                    23: expected=32'($signed(a)<$signed(b));
                    24: expected=32'(a<b);
                    25: expected=a^b;
                    26: expected=a>>b[4:0];
                    27: expected=$signed(a)>>>b[4:0];
                    28: expected=a|b;
                    29: expected=a&b;
                endcase
                if (taken) npc=target;
                exec_valid=1;
                exec_payload={5'd0,2'd0,6'(op),6'd32,pc,imm,(ISOLATE!=0 && control_flow)?~a:a,b};
                @(posedge clock); #1;
                if (!result_valid || result_payload!=={5'd0,6'd32,expected})
                    $fatal(1,"shared ALU op=%0d a=%h b=%h imm=%h got=%h expected=%h",
                        op,a,b,imm,result_payload[31:0],expected);
                if (resolve_valid!=control_flow || (control_flow && resolve_payload[31:0]!==npc))
                    $fatal(1,"shared branch computation op=%0d got=%h expected=%h",op,resolve_payload[31:0],npc);
                @(negedge clock);
            end
        end
        $display("PASS shared ALU: 2784 arithmetic, shift and branch vectors");
        $finish;
    end
endmodule
