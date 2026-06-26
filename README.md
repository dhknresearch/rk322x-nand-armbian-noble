# rk322x-nand-armbian-noble
A weird project by me. The main objective is to bring up Armbian Noble to some RK322x nand device that only work with kernel 4.4 and below.
I made this because I had recently received a RK3229 tvbox from a friend. It is nand version and the latest Armbian build I could find that booted is 21.08. But i need newer Armbian so that why I tried to build Armbian 26.08 based on Ubuntu Noble with legacy kernel 4.4.194 and somehow it worked. I did include xfce in this because I need GUI.

**What is working:** 
- GUI
- RK3229 device
- HDMI
- Wifi
- Falkon browser (I didn't figure out yet why Firefox not working)
- Etc.

**How to install:**
- Step 1: Download Multitool: https://apt.undo.it:7243/multitool-rk322x.xz
- Step 2: Use rufus to write Multitool to your sdcard
- Step 3: Use Minitool partition to enlarge the Multitool drive
- Step 4: Download the Armbian build in the release section and copy the image to the images folder inside Multitool drive
- Step 5: Plug the sdcard to your RK322x device, turn it on and choose erase nand if you have installed any OS
- Step 6: Burn Armbian image via steP-nand
- Step 7: Shutdown, turn on and setup Armbian
- Step 8: Enjoy

Feel free to create issues and help me to fix this. Thank to @thinhx2 to mention the nand legacy problem and @jock for his previous work on legacy kernel Armbian for RK322x.
