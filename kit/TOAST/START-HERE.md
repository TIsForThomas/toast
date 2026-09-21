# TOAST Image Capture Kit — START HERE

This USB drive makes a copy of this computer, exactly as you have set it up, so
that whoever builds your computers can build more of them the same way.

**Four steps, in this order.** Step 3 only works straight after step 2.

Before you start, check:

- [ ] The computer is set up exactly how you want it copied.
- [ ] Windows has been restarted, with no updates waiting to install.
- [ ] BitLocker is **off** and the drive is fully decrypted.
- [ ] Mains power is connected. The whole thing can take up to an hour.

---

## 1. Plug in this USB drive and run one file

Open the drive, open the `TOAST` folder, and double-click
**`Run-Toast-Prep.cmd`**. Click **Yes** when Windows asks for permission.

It asks you some questions about how computers built from this image should be
set up — user accounts, network settings, and a few options. Every question has
a safe default, so pressing Enter is fine if you are not sure.

It then prepares the image and **shuts the computer down by itself.** That is
normal and it means it worked.

---

## 2. DO NOT SWITCH IT BACK ON NORMALLY

### Switch it on and boot from the USB drive.

As soon as you power on, press the boot-menu key repeatedly — on most
computers this is usually **F7**, **F11**, **Esc** or **Del** — then choose the
USB drive from the list that appears.

**If Windows is allowed to start first, the preparation is undone and step 1 has
to be done again.** Nothing you have set up on the computer is lost either way —
it comes back exactly as it is now.

---

## 3. Let it copy the drive. Do not touch anything.

A short menu appears first. The top entry, **TOAST: Capture image from this
unit**, is already highlighted, so **press Enter**. The menu waits for you and
will not start on its own. The other entries are for support use and are not
part of these steps.

It then shows what it is about to copy and asks you to confirm. Answer **yes**.

If this drive already holds a copy from a previous run, it asks whether to keep
that one and make an additional copy, replace it, or stop. Keeping both is safe;
nothing is deleted unless you choose to replace.

After that it runs on its own with nothing more to answer. Expect **20 minutes
to an hour**, depending on how much is on the drive. It checks the copy, then
powers the computer off.

Partway through it will say it is preparing the Windows partition. Two things
happen there, both normal:

- It makes the partition temporarily smaller, so that computers built from your
  image can use drives of a different size. It puts it back to full size by
  itself before it finishes.
- It deletes Windows' own paging and hibernation files, which are often tens of
  gigabytes and would otherwise be copied for no reason. Windows recreates them
  by itself the next time it starts.

**None of your own files, programs or settings are touched.**

If it shows a red failure message instead, stop and contact us. Do not send
anything.

---

## 4. Switch on normally, then send us two things

Windows starts up exactly as it was. From this USB drive, send us:

- the folder `\home\partimag\` — this is the copy of your computer
- the file `\TOAST\config\unattend.xml` — how you asked it to be set up

Your supplier will tell you where to send them. The copy is usually tens
of gigabytes, so it goes by file transfer, not email.

The computer can go straight back into service. **The USB drive is yours to
keep** — there is nothing to return.

---

## If anything looks wrong

Stop, and go back to your supplier before trying again.

**If the computer lost power during step 3**, boot this USB drive again and pick
**"TOAST: Repair disk space after an interrupted capture"** from the menu.
Windows will still start normally either way and nothing has been lost, but
until that is done, part of the drive is unusable. It takes a few minutes and
asks nothing.

There is a log on this USB drive in `\TOAST\logs\`. Send it with your message,
and say which kit version you have (it is in `\TOAST\KIT-VERSION.txt`). It
tells us exactly what happened and saves a lot of guessing.
