# Library API

Run from this directory using Java 21 and a running MySQL server.
Create the `library_db` database if it does not already exist.

In PowerShell, set a valid MySQL password and start the application:

```powershell
$env:DB_USERNAME = 'root'
$env:DB_PASSWORD = 'your-actual-mysql-password'
.\mvnw.cmd spring-boot:run
```

The default database URL is `jdbc:mysql://localhost:3306/library_db`.
Set `DB_URL` to override it. Hibernate creates or updates the tables.
The books endpoint is `http://localhost:8080/api/books`.

If startup reports `Access denied for user`, verify the same username and
password with the MySQL client (`mysql -u root -p`). The password must match
the MySQL account; changing the application setting does not change that account.
