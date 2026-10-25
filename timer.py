import time
import serial

ser=serial.Serial(
    input("COM Port: "),
    int(input("Baudrate: ")),
    timeout=10000,
)

senddata=[0x73]
sendbinary=bytes(senddata)

a=0
timea=0
pi = "3.1415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679"
while a < 100:
    time_s=time.perf_counter()
    ser.write(sendbinary)
    while True:
        raw_data = ser.readline()
        pi_str = raw_data.decode('utf-8', errors='ignore').strip()
        if pi_str.startswith(pi):
            break
    time_e=time.perf_counter()
    timeo=time_e-time_s
    timea+=timeo
    a+=1
print(timea/a)
    






    