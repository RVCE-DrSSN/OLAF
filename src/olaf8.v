`default_nettype none

module tt_um_olaf8(
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire ena,
    input  wire clk,
    input  wire rst_n
);

    wire [3:0] y;
    wire done, admitted, busy;

    olaf8_core core(
        .x1(ui_in[7:4]), .x2(ui_in[3:0]),
        .start(uio_in[0] & ena), .clk(clk), .rst_n(rst_n),
        .y(y), .done(done), .admitted(admitted), .busy(busy)
    );

    assign uo_out  = {1'b0,busy,admitted,done,y};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

endmodule


module olaf8_core(
    input  wire [3:0] x1, x2,
    input  wire start, clk, rst_n,
    output reg [3:0] y,
    output reg done, admitted, busy
);

    /*
     * One packed word per bounded rule:
     * [10:9] a1, [8:7] a2, [6:3] consequent, [2:0] utility.
     */
    reg [10:0] rule [0:7];

    reg [3:0] x1_r, x2_r;
    reg [2:0] idx;
    reg [2:0] min_idx;
    reg [2:0] min_u;
    reg [3:0] max_fire;
    reg [2:0] max_idx;

    /*
     * Shared accumulation state.
     * numerator <= 8*15*15 = 1800
     * denominator <= 8*15 = 120
     */
    reg [10:0] num;
    reg [6:0] den;

    /*
     * Quotient state. Only a 4-bit saturated output is required.
     * At most 15 useful subtractions are needed.
     */
    reg [10:0] qnum;
    reg [6:0] qden;
    reg [3:0] q;
    reg [3:0] qcount;

    reg [1:0] state;
    localparam IDLE=2'd0, SCAN=2'd1, QUOT=2'd2;

    function [3:0] mf;
        input [3:0] x;
        input [1:0] l;
        begin
            case(l)
                2'd0: begin
                    case(x)
                        0:mf=15; 1:mf=13; 2:mf=11; 3:mf=9;
                        4:mf=7;  5:mf=5;  6:mf=3;  7:mf=1;
                        default:mf=0;
                    endcase
                end
                2'd1: begin
                    case(x)
                        0:mf=0;  1:mf=2;  2:mf=4;  3:mf=6;
                        4:mf=8;  5:mf=10; 6:mf=12; 7:mf=14;
                        8:mf=14; 9:mf=12; 10:mf=10; 11:mf=8;
                        12:mf=6; 13:mf=4; 14:mf=2; default:mf=0;
                    endcase
                end
                default: begin
                    case(x)
                        0,1,2,3,4,5,6,7:mf=0;
                        8:mf=2; 9:mf=4; 10:mf=6; 11:mf=8;
                        12:mf=10; 13:mf=12; 14:mf=14; default:mf=15;
                    endcase
                end
            endcase
        end
    endfunction

    function [1:0] peak;
        input [3:0] x;
        begin
            if(x<=3) peak=0;
            else if(x<=11) peak=1;
            else peak=2;
        end
    endfunction

    wire [1:0] a1 = rule[idx][10:9];
    wire [1:0] a2 = rule[idx][8:7];
    wire [3:0] ry = rule[idx][6:3];
    wire [2:0] ru = rule[idx][2:0];

    wire [3:0] m1 = mf(x1_r,a1);
    wire [3:0] m2 = mf(x2_r,a2);
    wire [3:0] fire = (m1<m2)?m1:m2;

    /*
     * Small 4x4 product. The synthesizer can share the add structure.
     */
    wire [7:0] p =
        (fire[0] ? {4'b0,ry} : 8'b0) +
        (fire[1] ? {3'b0,ry,1'b0} : 8'b0) +
        (fire[2] ? {2'b0,ry,2'b0} : 8'b0) +
        (fire[3] ? {1'b0,ry,3'b0} : 8'b0);

    wire [10:0] nlast = num + {3'b0,p};
    wire [6:0]  dlast = den + {3'b0,fire};

    wire [3:0] fmax = (fire>max_fire)?fire:max_fire;
    wire [2:0] imax = (fire>max_fire)?idx:max_idx;

    wire qsub = (qnum >= {4'b0,qden});

    /*
     * Finalize operation in one common path. This avoids duplicating
     * admission/update logic in several FSM branches.
     */
    reg [3:0] final_y;
    reg final_admit;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state <= IDLE;
            y <= 4'd8;
            done <= 0;
            admitted <= 0;
            busy <= 0;

            x1_r <= 0;
            x2_r <= 0;
            idx <= 0;

            min_idx <= 0;
            min_u <= 7;
            max_fire <= 0;
            max_idx <= 0;

            num <= 0;
            den <= 0;

            qnum <= 0;
            qden <= 1;
            q <= 0;
            qcount <= 0;

            rule[0] <= 11'b00_00_0010_001;
            rule[1] <= 11'b00_01_0101_001;
            rule[2] <= 11'b00_10_0111_001;
            rule[3] <= 11'b01_00_0101_001;
            rule[4] <= 11'b01_01_1000_001;
            rule[5] <= 11'b01_10_1010_001;
            rule[6] <= 11'b10_00_0111_001;
            rule[7] <= 11'b10_10_1101_001;
        end else begin
            done <= 0;
            admitted <= 0;

            case(state)

                IDLE: begin
                    busy <= 0;
                    if(start) begin
                        x1_r <= x1;
                        x2_r <= x2;
                        idx <= 0;

                        min_idx <= 0;
                        min_u <= 7;

                        max_fire <= 0;
                        max_idx <= 0;

                        num <= 0;
                        den <= 0;

                        busy <= 1;
                        state <= SCAN;
                    end
                end

                SCAN: begin
                    busy <= 1;

                    num <= num + {3'b0,p};
                    den <= den + {3'b0,fire};

                    if(ru < min_u) begin
                        min_u <= ru;
                        min_idx <= idx;
                    end

                    if(fire > max_fire) begin
                        max_fire <= fire;
                        max_idx <= idx;
                    end

                    if(idx==7) begin
                        qnum <= nlast;
                        qden <= (dlast==0) ? 7'd1 : dlast;
                        q <= 0;
                        qcount <= 0;

                        max_fire <= fmax;
                        max_idx <= imax;

                        state <= QUOT;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                QUOT: begin
                    busy <= 1;

                    /*
                     * Zero denominator: baseline output behavior.
                     * Admission still occurs and receives y=8.
                     */
                    if(den==0) begin
                        final_y <= 0;
                        final_admit <= (max_fire < 6);
                        y <= 0;

                        if(max_fire < 6) begin
                            rule[min_idx][10:9] <= peak(x1_r);
                            rule[min_idx][8:7] <= peak(x2_r);
                            rule[min_idx][6:3] <= 4'd8;
                            rule[min_idx][2:0] <= 3'd4;
                            admitted <= 1;
                        end else if(rule[max_idx][2:0] != 7) begin
                            rule[max_idx][2:0] <= rule[max_idx][2:0] + 1'b1;
                        end

                        done <= 1;
                        busy <= 0;
                        state <= IDLE;

                    end else if(!qsub) begin
                        /*
                         * Exact floor quotient has been reached.
                         */
                        final_y <= q;
                        final_admit <= (max_fire < 6);
                        y <= q;

                        if(max_fire < 6) begin
                            rule[min_idx][10:9] <= peak(x1_r);
                            rule[min_idx][8:7] <= peak(x2_r);
                            rule[min_idx][6:3] <= q;
                            rule[min_idx][2:0] <= 3'd4;
                            admitted <= 1;
                        end else if(rule[max_idx][2:0] != 7) begin
                            rule[max_idx][2:0] <= rule[max_idx][2:0] + 1'b1;
                        end

                        done <= 1;
                        busy <= 0;
                        state <= IDLE;

                    end else if(q==4'd15 || qcount==4'd15) begin
                        /*
                         * Saturated 4-bit result.
                         */
                        y <= 4'd15;

                        if(max_fire < 6) begin
                            rule[min_idx][10:9] <= peak(x1_r);
                            rule[min_idx][8:7] <= peak(x2_r);
                            rule[min_idx][6:3] <= 4'd15;
                            rule[min_idx][2:0] <= 3'd4;
                            admitted <= 1;
                        end else if(rule[max_idx][2:0] != 7) begin
                            rule[max_idx][2:0] <= rule[max_idx][2:0] + 1'b1;
                        end

                        done <= 1;
                        busy <= 0;
                        state <= IDLE;

                    end else begin
                        qnum <= qnum - {4'b0,qden};
                        q <= q + 1'b1;
                        qcount <= qcount + 1'b1;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule

`default_nettype wire
