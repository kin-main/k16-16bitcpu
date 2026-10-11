from sim_test import SystemSoC

def test_loop():
    mem = {}
    with open("firmware.hex", "r") as f:
        lines = [line.strip() for line in f if line.strip()]
    for i, line in enumerate(lines):
        mem[i] = int(line, 16)
    
    # Use real CLKS_PER_BIT=234!
    soc = SystemSoC(mem, clks_per_bit=234)
    
    # Run until first message finishes (around cycle 25 * 2340 = 58,500)
    print("Running with CLKS_PER_BIT=234...")
    for cycle in range(150000):
        if soc.mmio.tx_start_q:
            ch = chr(soc.mmio.tx_hold_q)
            print(f"Cycle {cycle:6d}: TX '{ch}'")
        soc.step()

if __name__ == "__main__":
    test_loop()
