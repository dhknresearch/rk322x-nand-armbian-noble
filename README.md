# rk322x-nand-armbian-noble

A weird project by me. The main objective is to bring up Armbian Noble to some RK322x nand device that only work with kernel 4.4 and below.
I made this because I had recently received a RK3229 tvbox from a friend. It is nand version and the latest Armbian build I could find that booted is 21.08. But i need newer Armbian so that why I tried to build Armbian 26.08 based on Ubuntu Noble with legacy kernel 4.4.194 and somehow it worked. I did include xfce in this because I need GUI.

**Some screenshot:**
<img width="1280" height="720" alt="Screenshot_1" src="https://github.com/user-attachments/assets/dc1d1003-c1ca-4825-a058-9ccaa8ac8cc8" />
<img width="1280" height="720" alt="Screenshot_2" src="https://github.com/user-attachments/assets/e2658f9f-40b7-427c-94aa-b1cdc45f4baa" />

**What is working:**

* GUI
* RK3229 device
* HDMI
* Wifi
* Sdcard
* USB drive
* Falkon browser (I didn't figure out yet why Firefox not working)
* Etc.

**How to build:**

* Ensure you are on Linux based OS. Recommend Debian based OS
* Clone this repository
* Run build-noble.sh
* Enjoy
* Don't run build-resolute-\*.sh because it is still working in progress

**How to install:**

* Step 1: Download Multitool: https://apt.undo.it:7243/multitool-rk322x.xz
* Step 2: Use rufus to write Multitool to your sdcard
* Step 3: Use Minitool partition to enlarge the Multitool drive
* Step 4: Download the Armbian build in the release section and copy the image to the images folder inside Multitool drive
* Step 5: Plug the sdcard to your RK322x nand device, turn it on and choose erase nand if you have installed any OS
* Step 6: Burn Armbian image via steP-nand
* Step 7: Shutdown, turn on and setup Armbian
* Step 8: Enjoy

**Current state:**

* Noble build booting pretty well and probably need some more patches so it can working better and smoothier
* Resolute is still in demo stage because the systemd probably won't behave well on 4.4 kernel so I'm currently working on a patch.



Feel free to create issues and help me to fix this. Thank to @thinhx2 for mentioned the nand legacy problem and some useful advices and @jock for his previous work on legacy kernel Armbian for RK322x. Also thank to Armbian community for the RK322x official build that I used as base for this build.

