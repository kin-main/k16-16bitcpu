module top (
    input  wire clk,
    input  wire rst,

    output wire uart_tx
);

    reg [23:0] data;
    reg start;

    wire busy;
    wire done;

    uart_tx_24bit uart (
        .clk   (clk),
        .rst_n (rst_n),

        .data  (data),
        .start (start),

        .tx    (uart_tx),
        .busy  (busy),
        .done  (done)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data  <= 24'h123456;
            start <= 1'b0;
        end else begin
            start <= 1'b0;

            // UARTが空いていたら送信開始
            if (!busy) begin
                data  <= 24'h123456;
                start <= 1'b1;
            end
        end
    end

endmodule
