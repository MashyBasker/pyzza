for i in [1, 2, 3, 4, 5]:
    if i == 4:
        break
    if i == 2:
        continue
    print(i)

x = 0
while x < 10:
    x = x + 1
    if x == 5:
        continue
    if x == 8:
        break
    print(x)
