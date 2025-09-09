1) Install MySQL Server
sudo apt update
sudo apt -y install mysql-server
sudo systemctl enable --now mysql
systemctl status mysql --no-pager

(Recommended) Secure the server
sudo mysql_secure_installation


Answer the prompts (set a root password if asked, remove test DB, disallow anonymous users, etc.).

On Ubuntu, root often authenticates via the socket. You can always enter the shell with:

sudo mysql

2) Create your lab user (you’ll connect with this in Workbench)

Open the MySQL shell:

sudo mysql


Run these SQL commands (change the password):

-- Create a dedicated user for the lab:
CREATE USER 'lab_user'@'localhost' IDENTIFIED BY 'Str0ng!Passw0rd';

-- Give it permissions to create the sample DB and work with it:
GRANT ALL PRIVILEGES ON *.* TO 'lab_user'@'localhost';

FLUSH PRIVILEGES;
EXIT;


If you prefer least-privilege: after you create/import classicmodels, you can replace the global grant with
GRANT ALL PRIVILEGES ON classicmodels.* TO 'lab_user'@'localhost';

3) Install MySQL Workbench
Option A — Ubuntu repo (try this first)
sudo apt -y install mysql-workbench

Option B — Flatpak (if A isn’t available/too old)
sudo apt -y install flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
sudo flatpak install -y flathub com.mysql.Workbench
# Run it:
flatpak run com.mysql.Workbench

4) Connect in Workbench (using your lab user)

Open MySQL Workbench → click + beside “MySQL Connections”.

Connection Name: Local MySQL (lab_user)

Hostname: 127.0.0.1, Port: 3306

Username: lab_user

Store/enter the password you set (Str0ng!Passw0rd).

Test Connection → OK → Connect.

5) Load the sample database (classicmodels)

Your lab mentions a file called classicmodels_creationScript. Put that .sql file on the VM (e.g., ~/Downloads).

In Workbench:

File → Open SQL Script… → select the classicmodels_creationScript.sql.

Click the lightning bolt (Execute) to run it.

On the left, in SCHEMAS, right-click and Refresh All — you should see classicmodels appear with its tables.

6) Make the required query file

Create a new SQL tab in Workbench and paste this. Save as lab0_<yourStudentNumber>.txt (File → Save Script As…).

-- 1) Show all databases on the server
SHOW DATABASES;

-- 2) Use the 'classicmodels' database
USE classicmodels;

-- 3) Show all tables in 'classicmodels'
SHOW TABLES;

-- 4) Show table structure for one table (example: employees)
DESCRIBE employees;

-- 5) Run and briefly describe:

-- a) Retrieves every column and row from the employees table.
SELECT * FROM employees;

-- b) NOTE: The lab text says 'customer', but the actual table name in classicmodels is 'customers'.
-- This returns all rows from 'customers' and orders by the contact's last name (A→Z).
SELECT * FROM customers ORDER BY contactLastName;

-- 6) Show the current logged-in user (this must be YOUR created user)
SELECT current_user;


If your column name is cased differently in your script (e.g., ContactLastName), MySQL will still accept it. The canonical column is contactLastName.

7) Take the required screenshot

In the same SQL tab, run only:

SELECT current_user;


Ensure the Result Grid is visible (shows something like lab_user@localhost).

In the left pane, SCHEMAS should clearly show classicmodels expanded (or at least present).

Take a screenshot that shows:

the query SELECT current_user;

the result row

the SCHEMAS panel with classicmodels

Upload that screenshot to Blackboard. (Optionally upload your lab0_<studentnumber>.txt too.)

Quick troubleshooting

Workbench can’t connect / “Access denied”
Double-check username/password. In the MySQL shell:

SELECT user, host, plugin FROM mysql.user;


Ensure lab_user@localhost exists. If needed, reset:

ALTER USER 'lab_user'@'localhost' IDENTIFIED BY 'Str0ng!Passw0rd';
FLUSH PRIVILEGES;


Service down

sudo systemctl status mysql
sudo systemctl restart mysql


Script errors about missing table names
Confirm you opened the correct classicmodels_creationScript.sql. Refresh SCHEMAS and verify expected tables:
customers, employees, orders, orderdetails, payments, products, productlines, offices.

Minimal Server (no GUI)
You can install Workbench on your host OS and connect to the VM’s MySQL over the VM’s IP (or set a port-forward in VirtualBox). For local use in the VM, Desktop Ubuntu is simplest.
