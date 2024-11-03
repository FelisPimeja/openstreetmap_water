const apiBase = "http://localhost:3000/";
var errTable = "err_duplicated_ways";
var dropdown = document.getElementById("dropdown");
var currentPage = 1;
var rowsPerPage = 10;
var numPages;

const josmBase = "http://localhost:8111/load_and_zoom?";

function buildOsmLink(osmId) {
  const osmBase = "https://www.openstreetmap.org/";
  if (osmId < 0) {
    osmId = (osmId * -1)
    osmLink = "<a href=\"" + osmBase + "relation/" + osmId + "\">r" + osmId + "</a>"
  } else {
    osmLink = "<a href=\"" + osmBase + "way/" + osmId + "\">w" + osmId + "</a>";
  }
  return osmLink;
}

dropdown.addEventListener("change", function () {
  errTable = dropdown.value;
  var temp = "";
  var apiUrl = apiBase + errTable;
  
  fetch(apiUrl)
    .then((response) => {
      return response.json()
        .then((data) => {
          if (data.length > 0) {

            data.forEach((itemData) => {
              var bbox = itemData.bbox;
              var osmIds = itemData.osm_ids;
              var josmLink = josmBase + "left=" + bbox[0] + "&right=" + bbox[1] + "&top=" + bbox[2] + "&bottom=" + bbox[3] + "&select=w" + osmIds[0];

              temp += "<tr>";
              temp += "<td>" + buildOsmLink(osmIds[0]) + buildOsmLink(osmIds[1]) + "</td>";
              temp += "<td><a href=" + josmLink + " target=\"loader\">" + "Edit in JOSM</a></td></tr>";
            });
            document.getElementById('data').innerHTML = temp;
          }
        }
        )
    }
    );
});



// var current_page = 1;
// var records_per_page = 3;
// var l = document.getElementById("table").rows.length


// function prevPage() {
//   if (current_page > 1) {
//     current_page--;
//     changePage(current_page);
//   }
// }

// function nextPage() {
//   if (current_page < numPages()) {
//     current_page++;
//     changePage(current_page);
//   }
// }

// function changePage(page) {
//   var btn_next = document.getElementById("btn_next");
//   var btn_prev = document.getElementById("btn_prev");
//   var listing_table = document.getElementById("table");
//   var page_span = document.getElementById("page");

//   // Validate page
//   if (page < 1) page = 1;
//   if (page > numPages()) page = numPages();
//   console.log(listing_table.rows);
//   for (var i = 0; i < l; i++) {
//     listing_table.rows[i].style.display = "none"
//   }


//   for (var i = (page - 1) * records_per_page; i < (page * records_per_page); i++) {
//     listing_table.rows[i].style.display = "block"
//   }

//   page_span.innerHTML = page + "/" + numPages();

//   if (page == 1) {
//     btn_prev.style.visibility = "hidden";
//   } else {
//     btn_prev.style.visibility = "visible";
//   }

//   if (page == numPages()) {
//     btn_next.style.visibility = "hidden";
//   } else {
//     btn_next.style.visibility = "visible";
//   }
// }

// function numPages() {
//   return Math.ceil(l / records_per_page);
// }

// window.onload = function() {
//   changePage(1);
// };